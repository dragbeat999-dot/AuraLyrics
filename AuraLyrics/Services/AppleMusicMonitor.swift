import Foundation
import MediaPlayer
import Combine
import UIKit

/// Sumber lagu yang sedang diputar
public enum PlaybackSource: String, CaseIterable {
    case appleMusic
    case spotify
    case system // <--- INI YANG BIKIN ERROR KARENA TADI BELUM ADA
}

/// Apple Music 系統播放器監聽與即時時間軸推播器（已加入 Spotify & System 來源支援）
@MainActor
public final class AppleMusicMonitor: ObservableObject {
    public static let shared = AppleMusicMonitor()

    @Published public private(set) var currentTrack: TrackInfo = .placeholder
    @Published public private(set) var currentLyrics: SyncedLyrics = .empty
    @Published public var currentLineIndex: Int? = nil
    @Published public private(set) var isPlaying: Bool = false
    public private(set) var playbackProgress: Double = 0.0
    public private(set) var currentPlaybackTimeSec: TimeInterval = 0.0
    public private(set) var lastTickTimestamp: CFTimeInterval = CACurrentMediaTime()
    @Published public private(set) var isLoadingLyrics: Bool = false
    
    // --- VARIABEL UNTUK TERJEMAHAN ---
    @Published public private(set) var isTranslatingLyrics: Bool = false

    /// 全域歌詞同步時間微調偏移量（毫秒，每首歌共用）
    @Published public var globalOffsetMs: Int {
        didSet {
            UserDefaults.standard.set(globalOffsetMs, forKey: "globalLyricsOffsetMs")
        }
    }

    /// Sumber pemutar yang dipantau
    @Published public var playbackSource: PlaybackSource {
        didSet {
            guard oldValue != playbackSource else { return }
            UserDefaults.standard.set(playbackSource.rawValue, forKey: "playbackSource")
            handleSourceChanged()
        }
    }

    @Published public private(set) var spotifyStatusMessage: String? = nil

    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private let timerQueue = DispatchQueue(label: "com.auralyrics.monitor.timerQueue", qos: .userInteractive)
    private var timerSource: DispatchSourceTimer?
    private var isInBackground: Bool = false
    private var lastHeartbeatTimestamp: CFTimeInterval = 0.0

    // MARK: - 高精度防抖時鐘錨點
    private var anchorPlaybackTimeSec: TimeInterval = 0.0
    private var anchorMediaTime: CFTimeInterval = 0.0

    // MARK: - 換歌追蹤與非同步任務管理
    private var lastPersistentID: MPMediaEntityPersistentID = 0
    private var lastPlaybackStoreID: String = ""
    private var lastPlaybackTimeSec: TimeInterval = 0.0
    private var lyricsFetchTask: Task<Void, Never>? = nil

    // MARK: - Spotify & System Polling
    private var externalPollTask: Task<Void, Never>? = nil
    private var lastSpotifyTrackID: String = ""
    private var lastSystemTrackID: String = ""
    private var spotifyBackoffSec: TimeInterval = 0

    private init() {
        self.globalOffsetMs = UserDefaults.standard.integer(forKey: "globalLyricsOffsetMs")
        self.playbackSource = PlaybackSource(rawValue: UserDefaults.standard.string(forKey: "playbackSource") ?? "") ?? .appleMusic
        setupNotifications()
    }

    // MARK: - 系統通知與生命週期設定
    private func setupNotifications() {
        musicPlayer.beginGeneratingPlaybackNotifications()

        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTrackChanged()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackStateChanged()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = true
                let now = CACurrentMediaTime()
                if self.isPlaying {
                    let currentExact = self.anchorPlaybackTimeSec + max(0, now - self.anchorMediaTime)
                    self.anchorPlaybackTimeSec = currentExact
                    self.anchorMediaTime = now
                }
                self.syncExternalEngines()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = false
                self.musicPlayer.beginGeneratingPlaybackNotifications()
                if self.playbackSource == .appleMusic {
                    self.handleTrackChanged(force: true)
                    self.handlePlaybackStateChanged()
                } else {
                    self.refreshExternalNow()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isInBackground = false
                if self.playbackSource == .appleMusic {
                    self.handleTrackChanged()
                    self.handlePlaybackStateChanged()
                } else {
                    self.refreshExternalNow()
                }
            }
        }
    }

    // MARK: - 啟動監聽與高精度時間軸定時器
    public func startMonitoring() {
        if playbackSource == .appleMusic {
            handleTrackChanged(force: true)
            handlePlaybackStateChanged()
        }

        stopTimer()

        let source = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        source.schedule(deadline: .now(), repeating: .milliseconds(150), leeway: .milliseconds(20))
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        source.resume()
        self.timerSource = source

        if playbackSource != .appleMusic {
            startExternalPolling()
        }
    }

    private func stopTimer() {
        timerSource?.cancel()
        timerSource = nil
    }

    public func stopMonitoring() {
        stopTimer()
        externalPollTask?.cancel()
        externalPollTask = nil
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        musicPlayer.endGeneratingPlaybackNotifications()
    }

    // MARK: - Ganti sumber pemutar
    private func handleSourceChanged() {
        externalPollTask?.cancel()
        externalPollTask = nil
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil

        isLoadingLyrics = false
        currentTrack = .placeholder
        currentLyrics = .empty
        currentLineIndex = nil
        isPlaying = false
        playbackProgress = 0.0
        currentPlaybackTimeSec = 0.0
        anchorPlaybackTimeSec = 0.0
        anchorMediaTime = 0.0
        lastPersistentID = 0
        lastPlaybackStoreID = ""
        lastPlaybackTimeSec = 0.0
        lastSpotifyTrackID = ""
        lastSystemTrackID = ""
        spotifyBackoffSec = 0
        spotifyStatusMessage = nil
        syncExternalEngines()

        guard timerSource != nil else { return }
        
        if playbackSource == .appleMusic {
            handleTrackChanged(force: true)
            handlePlaybackStateChanged()
        } else {
            startExternalPolling()
        }
    }

    // MARK: - 曲目變更處理 (Apple Music)
    private func handleTrackChanged(force: Bool = false) {
        guard playbackSource == .appleMusic else { return }

        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            if isInBackground { return }
            lyricsFetchTask?.cancel()
            lyricsFetchTask = nil
            currentTrack = .placeholder
            currentLyrics = .empty
            currentLineIndex = nil
            playbackProgress = 0.0
            anchorPlaybackTimeSec = 0
            anchorMediaTime = 0
            lastPersistentID = 0
            lastPlaybackStoreID = ""
            lastPlaybackTimeSec = 0
            syncExternalEngines()
            return
        }

        let persistentID = nowPlaying.persistentID
        let playbackStoreID = nowPlaying.playbackStoreID ?? ""
        let title = nowPlaying.title ?? String(localized: "未知曲目")
        let artist = nowPlaying.artist ?? String(localized: "未知歌手")
        let album = nowPlaying.albumTitle ?? ""
        let duration = nowPlaying.playbackDuration
        let genre = nowPlaying.genre ?? ""

        if !force && lastPersistentID != 0 && lastPersistentID == persistentID && currentTrack.title == title && currentTrack.artist == artist && (!currentLyrics.lines.isEmpty || isLoadingLyrics) {
            return
        }

        lastPersistentID = persistentID
        lastPlaybackStoreID = playbackStoreID

        var artworkData: Data? = nil
        if let artwork = nowPlaying.artwork {
            if let image = artwork.image(at: CGSize(width: 120, height: 120)) {
                artworkData = image.pngData()
            }
        }

        let newTrack = TrackInfo(title: title, artist: artist, album: album, duration: duration, artworkData: artworkData, genre: genre)
        currentTrack = newTrack
        currentLyrics = .empty
        currentLineIndex = nil
        playbackProgress = 0.0

        let rawPlayTime = musicPlayer.currentPlaybackTime
        let validInitialPlayTime = (!rawPlayTime.isNaN && !rawPlayTime.isInfinite && rawPlayTime >= 0.0 && rawPlayTime < 3.0) ? rawPlayTime : 0.0

        currentPlaybackTimeSec = validInitialPlayTime
        anchorPlaybackTimeSec = validInitialPlayTime
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = validInitialPlayTime
        syncExternalEngines()

        lyricsFetchTask?.cancel()
        lyricsFetchTask = Task { [weak self] in
            guard let self = self else { return }
            self.isLoadingLyrics = true
            let fetched = await LyricsProviderService.shared.fetchLyrics(track: newTrack)
            guard !Task.isCancelled else { return }
            if let fetched = fetched {
                self.currentLyrics = fetched
                
                if UserDefaults.standard.bool(forKey: "enableAutoTranslation") {
                    Task { @MainActor in await self.translateCurrentLyrics() }
                }
                
                let nowPlayTime = self.musicPlayer.currentPlaybackTime
                if !nowPlayTime.isNaN && !nowPlayTime.isInfinite && nowPlayTime >= 0.0 && (newTrack.duration <= 0 || nowPlayTime < newTrack.duration) {
                    self.anchorPlaybackTimeSec = nowPlayTime
                    self.anchorMediaTime = CACurrentMediaTime()
                    self.currentPlaybackTimeSec = nowPlayTime
                    self.lastPlaybackTimeSec = nowPlayTime
                }
            } else {
                self.currentLyrics = SyncedLyrics.empty
            }
            self.refreshCurrentLineIndex(forceSync: true)
            self.isLoadingLyrics = false
        }
    }

    private func handlePlaybackStateChanged() {
        guard playbackSource == .appleMusic else { return }

        let newIsPlaying = (musicPlayer.playbackState == .playing)
        if isPlaying != newIsPlaying {
            isPlaying = newIsPlaying
            let playTime = musicPlayer.currentPlaybackTime
            if !playTime.isNaN && !playTime.isInfinite && playTime >= 0 {
                if !newIsPlaying && abs(playTime - currentPlaybackTimeSec) < 0.4 {
                    anchorPlaybackTimeSec = currentPlaybackTimeSec
                } else {
                    anchorPlaybackTimeSec = playTime
                    currentPlaybackTimeSec = playTime
                }
            }
            anchorMediaTime = CACurrentMediaTime()
            syncExternalEngines()

            if newIsPlaying {
                LiveActivityLyricsEngine.shared.handlePlaybackResumed(track: currentTrack)
            } else {
                LiveActivityLyricsEngine.shared.handlePlaybackPaused()
            }
        }
    }

    // MARK: - 時間軸定時器循環
    private func tick() {
        if playbackSource == .spotify {
            tickSpotify()
            return
        }
        if playbackSource == .system {
            tickSystem()
            return
        }

        let now = CACurrentMediaTime()
        lastTickTimestamp = now

        if let nowPlaying = musicPlayer.nowPlayingItem {
            let pid = nowPlaying.persistentID
            let storeID = nowPlaying.playbackStoreID ?? ""
            let title = nowPlaying.title ?? ""
            let artist = nowPlaying.artist ?? ""

            let isPidChanged = (pid != 0 && pid != lastPersistentID)
            let isStoreIDChanged = (!storeID.isEmpty && storeID != lastPlaybackStoreID)
            let isInfoChanged = (!title.isEmpty && (title != currentTrack.title || artist != currentTrack.artist))

            if isPidChanged || isStoreIDChanged || isInfoChanged {
                handleTrackChanged()
                return
            }

            if currentTrack.duration <= 0 && nowPlaying.playbackDuration > 0 {
                let updatedTrack = TrackInfo(title: currentTrack.title, artist: currentTrack.artist, album: currentTrack.album, duration: nowPlaying.playbackDuration, artworkData: currentTrack.artworkData, genre: currentTrack.genre.isEmpty ? (nowPlaying.genre ?? "") : currentTrack.genre)
                currentTrack = updatedTrack
            }
        } else if !isInBackground && currentTrack.title != TrackInfo.placeholder.title {
            handleTrackChanged()
            return
        }

        let playTime = musicPlayer.currentPlaybackTime
        let isPlayTimeValid = !playTime.isNaN && !playTime.isInfinite && playTime >= 0
        let playTimeDelta = isPlayTimeValid ? (playTime - lastPlaybackTimeSec) : 0
        let hasFreshAdvance = isPlayTimeValid && (playTimeDelta > 0.05 && playTimeDelta < 2.0)

        if !isInBackground {
            let actualIsPlaying = (musicPlayer.playbackState == .playing)
            if isPlaying != actualIsPlaying {
                handlePlaybackStateChanged()
                return
            }
        } else if hasFreshAdvance && !isPlaying {
            isPlaying = true
            anchorPlaybackTimeSec = playTime
            anchorMediaTime = now
            LiveActivityLyricsEngine.shared.handlePlaybackResumed(track: currentTrack)
        }

        if isPlaying {
            let predictedTime = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)
            let isInitialStart = (anchorPlaybackTimeSec == 0 && playTime > 0.05 && playTime < 5.0 && hasFreshAdvance)
            let playTimeJump = abs(playTime - lastPlaybackTimeSec)
            let isUserSeek = isPlayTimeValid && (playTimeJump > 1.2 && abs(playTime - predictedTime) > 1.0)
            let hasSignificantDrift = isPlayTimeValid && playTime > 0.5 && (abs(playTime - predictedTime) > 1.5)

            if isUserSeek || isInitialStart || hasSignificantDrift || anchorMediaTime == 0 {
                anchorPlaybackTimeSec = playTime
                anchorMediaTime = now
                currentPlaybackTimeSec = playTime
            } else {
                currentPlaybackTimeSec = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)
            }
        } else {
            let isUserSeek = isPlayTimeValid && abs(playTime - currentPlaybackTimeSec) > 0.5
            if isUserSeek {
                anchorPlaybackTimeSec = playTime
                currentPlaybackTimeSec = playTime
                anchorMediaTime = now
                lastPlaybackTimeSec = playTime
                if currentTrack.duration > 0 {
                    playbackProgress = min(max(currentPlaybackTimeSec / currentTrack.duration, 0.0), 1.0)
                    if abs(PiPLyricsViewModel.shared.progress - playbackProgress) > 0.002 {
                        PiPLyricsViewModel.shared.progress = playbackProgress
                    }
                }
                refreshCurrentLineIndex(forceSync: true)
            }
            return
        }

        if isPlayTimeValid && playTime > 0 {
            lastPlaybackTimeSec = playTime
        }

        if currentTrack.duration > 0 {
            playbackProgress = min(max(currentPlaybackTimeSec / currentTrack.duration, 0.0), 1.0)
            if abs(PiPLyricsViewModel.shared.progress - playbackProgress) > 0.002 {
                PiPLyricsViewModel.shared.progress = playbackProgress
            }
        }

        refreshCurrentLineIndex()
    }

    // MARK: - Polling untuk Spotify & System
    private func startExternalPolling() {
        externalPollTask?.cancel()
        externalPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                
                if self.playbackSource == .spotify {
                    await self.pollSpotifyOnce()
                } else if self.playbackSource == .system {
                    await self.pollSystemOnce()
                }
                
                let isExternalPlaying = self.isPlaying
                var interval: TimeInterval = isExternalPlaying ? 1.0 : 3.0
                if self.spotifyBackoffSec > 0 && self.playbackSource == .spotify { interval = self.spotifyBackoffSec }
                
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func refreshExternalNow() {
        guard playbackSource != .appleMusic else { return }
        Task {
            if playbackSource == .spotify { await pollSpotifyOnce() }
            else if playbackSource == .system { await pollSystemOnce() }
        }
    }

    // MARK: - TRIK KOTOR: System Polling (YouTube Music, dll)
    private func pollSystemOnce() async {
        guard playbackSource == .system else { return }
        
        guard let result = await SystemMediaMonitor.shared.fetchNowPlaying() else {
            if isPlaying {
                isPlaying = false
                anchorPlaybackTimeSec = currentPlaybackTimeSec
                anchorMediaTime = CACurrentMediaTime()
                syncExternalEngines()
                LiveActivityLyricsEngine.shared.handlePlaybackPaused()
            }
            return
        }

        let track = result.track
        let elapsed = result.elapsed
        let playing = result.isPlaying
        let isNewTrack = (track.title != lastSystemTrackID)

        let wasPlaying = isPlaying
        isPlaying = playing

        if isNewTrack {
            lastSystemTrackID = track.title
            handleSystemTrackChanged(track)
        }

        if playing {
            if isNewTrack || !wasPlaying {
                anchorPlaybackTimeSec = elapsed
            } else {
                let predicted = anchorPlaybackTimeSec + max(0, CACurrentMediaTime() - anchorMediaTime)
                let diff = elapsed - predicted
                if abs(diff) > 1.5 {
                    anchorPlaybackTimeSec = elapsed
                } else {
                    anchorPlaybackTimeSec = predicted + diff * 0.25
                }
            }
            anchorMediaTime = CACurrentMediaTime()
            currentPlaybackTimeSec = anchorPlaybackTimeSec
            
            if track.duration > 0 {
                playbackProgress = min(max(currentPlaybackTimeSec / track.duration, 0.0), 1.0)
                PiPLyricsViewModel.shared.progress = playbackProgress
            }

            if !wasPlaying {
                syncExternalEngines()
                LiveActivityLyricsEngine.shared.handlePlaybackResumed(track: currentTrack)
            }
        } else {
            let moved = abs(elapsed - currentPlaybackTimeSec) > 0.5
            anchorPlaybackTimeSec = elapsed
            anchorMediaTime = CACurrentMediaTime()
            currentPlaybackTimeSec = elapsed

            if wasPlaying || moved || isNewTrack {
                refreshCurrentLineIndex(forceSync: true)
                LiveActivityLyricsEngine.shared.handlePlaybackPaused()
            }
        }
    }

    private func handleSystemTrackChanged(_ track: TrackInfo) {
        currentTrack = track
        currentLyrics = .empty
        currentLineIndex = nil
        playbackProgress = 0.0
        syncExternalEngines()

        lyricsFetchTask?.cancel()
        lyricsFetchTask = Task { [weak self] in
            guard let self = self else { return }
            self.isLoadingLyrics = true
            let fetched = await LyricsProviderService.shared.fetchLyrics(track: track)
            guard !Task.isCancelled else { return }
            self.currentLyrics = fetched ?? SyncedLyrics.empty
            
            if UserDefaults.standard.bool(forKey: "enableAutoTranslation") {
                Task { @MainActor in await self.translateCurrentLyrics() }
            }
            
            self.refreshCurrentLineIndex(forceSync: true)
            self.isLoadingLyrics = false
        }
    }

    private func tickSystem() {
        let now = CACurrentMediaTime()
        lastTickTimestamp = now
        guard isPlaying else { return }
        
        var t = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)
        if currentTrack.duration > 0 { t = min(t, currentTrack.duration) }
        currentPlaybackTimeSec = t
        updatePlaybackProgress()
        refreshCurrentLineIndex()
    }

    // MARK: - Spotify Polling
    private func pollSpotifyOnce() async {
        guard playbackSource == .spotify else { return }
        guard SpotifyAuthManager.shared.isLoggedIn else {
            spotifyStatusMessage = "Belum masuk ke Spotify."
            return
        }
        do {
            let snapshot = try await SpotifyPlaybackClient.shared.fetchCurrentlyPlaying()
            guard !Task.isCancelled, playbackSource == .spotify else { return }
            spotifyBackoffSec = 0
            spotifyStatusMessage = nil
            applySpotifySnapshot(snapshot)
        } catch SpotifyError.rateLimited(let retryAfter) {
            spotifyBackoffSec = max(retryAfter, 5)
            spotifyStatusMessage = SpotifyError.rateLimited(retryAfter).errorDescription
        } catch {
            if !Task.isCancelled { spotifyStatusMessage = error.localizedDescription }
        }
    }

    private func applySpotifySnapshot(_ snapshot: SpotifyPlaybackSnapshot?) {
        let now = CACurrentMediaTime()
        guard let snap = snapshot else {
            if isPlaying {
                isPlaying = false
                anchorPlaybackTimeSec = currentPlaybackTimeSec
                anchorMediaTime = now
                syncExternalEngines()
                LiveActivityLyricsEngine.shared.handlePlaybackPaused()
            }
            return
        }

        let wasPlaying = isPlaying
        isPlaying = snap.isPlaying
        let isNewTrack = (snap.trackID != lastSpotifyTrackID)
        if isNewTrack { handleSpotifyTrackChanged(snap) }

        if snap.isPlaying {
            if isNewTrack || !wasPlaying {
                anchorPlaybackTimeSec = snap.progressSec
            } else {
                let predicted = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)
                let diff = snap.progressSec - predicted
                if abs(diff) > 1.0 {
                    anchorPlaybackTimeSec = snap.progressSec
                } else {
                    anchorPlaybackTimeSec = predicted + diff * 0.25
                }
            }
            anchorMediaTime = now
            currentPlaybackTimeSec = anchorPlaybackTimeSec
            updatePlaybackProgress()
            if !wasPlaying {
                syncExternalEngines()
                LiveActivityLyricsEngine.shared.handlePlaybackResumed(track: currentTrack)
            }
        } else {
            let moved = abs(snap.progressSec - currentPlaybackTimeSec) > 0.5
            anchorPlaybackTimeSec = snap.progressSec
            anchorMediaTime = now
            currentPlaybackTimeSec = snap.progressSec
            updatePlaybackProgress()
            if wasPlaying {
                refreshCurrentLineIndex(forceSync: true)
                LiveActivityLyricsEngine.shared.handlePlaybackPaused()
            } else if moved || isNewTrack {
                refreshCurrentLineIndex(forceSync: true)
            }
        }
    }

    private func handleSpotifyTrackChanged(_ snap: SpotifyPlaybackSnapshot) {
        lastSpotifyTrackID = snap.trackID
        let newTrack = TrackInfo(title: snap.title, artist: snap.artist, album: snap.album, duration: snap.durationSec, artworkData: nil, genre: "")
        currentTrack = newTrack
        currentLyrics = .empty
        currentLineIndex = nil
        playbackProgress = 0.0
        currentPlaybackTimeSec = snap.progressSec
        anchorPlaybackTimeSec = snap.progressSec
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = snap.progressSec
        syncExternalEngines()

        if let url = snap.artworkURL {
            let trackID = snap.trackID
            Task { [weak self] in
                let data = await Self.downloadArtworkData(from: url)
                guard let self = self, let data = data, self.lastSpotifyTrackID == trackID else { return }
                let t = self.currentTrack
                self.currentTrack = TrackInfo(title: t.title, artist: t.artist, album: t.album, duration: t.duration, artworkData: data, genre: t.genre)
                self.syncExternalEngines()
            }
        }

        lyricsFetchTask?.cancel()
        lyricsFetchTask = Task { [weak self] in
            guard let self = self else { return }
            self.isLoadingLyrics = true
            let fetched = await LyricsProviderService.shared.fetchLyrics(track: newTrack)
            guard !Task.isCancelled else { return }
            self.currentLyrics = fetched ?? SyncedLyrics.empty

            if UserDefaults.standard.bool(forKey: "enableAutoTranslation") {
                Task { @MainActor in await self.translateCurrentLyrics() }
            }

            self.refreshCurrentLineIndex(forceSync: true)
            self.isLoadingLyrics = false
        }
    }

    private func tickSpotify() {
        let now = CACurrentMediaTime()
        lastTickTimestamp = now
        guard isPlaying else { return }
        var t = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)
        if currentTrack.duration > 0 { t = min(t, currentTrack.duration) }
        currentPlaybackTimeSec = t
        updatePlaybackProgress()
        refreshCurrentLineIndex()
    }

    private func updatePlaybackProgress() {
        guard currentTrack.duration > 0 else { return }
        playbackProgress = min(max(currentPlaybackTimeSec / currentTrack.duration, 0.0), 1.0)
        if abs(PiPLyricsViewModel.shared.progress - playbackProgress) > 0.002 {
            PiPLyricsViewModel.shared.progress = playbackProgress
        }
    }

    private nonisolated static func downloadArtworkData(from url: URL) async -> Data? {
        guard let result = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: result.0) else { return nil }
        let size = CGSize(width: 120, height: 120)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        return resized.pngData()
    }

    /// 統一依據高精度插值時鐘重新計算當前歌詞行索引，並同步推播至各引擎
    private func refreshCurrentLineIndex(forceSync: Bool = false) {
        let accurateTimeMs = interpolatedPlaybackTimeMs()
        let newIndex = currentLyrics.currentLineIndex(at: accurateTimeMs, globalOffsetMs: 0)

        var nextLineIntervalSec: TimeInterval? = nil
        if let idx = newIndex, idx + 1 < currentLyrics.lines.count {
            let nextStartMs = currentLyrics.lines[idx + 1].timeMs
            nextLineIntervalSec = max(0.5, Double(nextStartMs - accurateTimeMs) / 1000.0)
        }

        if !isPlaying && !forceSync { return }

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
            lastHeartbeatTimestamp = CACurrentMediaTime()
            syncExternalEngines(nextLineIntervalSec: nextLineIntervalSec)
        } else if forceSync {
            lastHeartbeatTimestamp = CACurrentMediaTime()
            syncExternalEngines(nextLineIntervalSec: nextLineIntervalSec)
        } else {
            let now = CACurrentMediaTime()
            if isPlaying && (now - lastHeartbeatTimestamp >= 4.0) {
                lastHeartbeatTimestamp = now
                LiveActivityLyricsEngine.shared.sendHeartbeat(track: currentTrack)
            }
        }
    }

    public func syncExternalEngines(nextLineIntervalSec: TimeInterval? = nil) {
        let showTranslation = UserDefaults.standard.object(forKey: "showBilingualLyrics") as? Bool ?? true

        if let index = currentLineIndex, currentLyrics.lines.indices.contains(index) {
            let current = currentLyrics.lines[index]
            var secondaryText: String? = nil
            if showTranslation, let trans = current.translation, !trans.isEmpty {
                secondaryText = trans
            } else if index + 1 < currentLyrics.lines.count {
                secondaryText = currentLyrics.lines[index + 1].text
            }

            let nextLineText = (index + 1 < currentLyrics.lines.count) ? currentLyrics.lines[index + 1].text : nil

            PiPLyricsEngine.shared.updateLyrics(line: current.text, secondaryLine: nextLineText, progress: playbackProgress)
            LiveActivityLyricsEngine.shared.updateLyrics(line: current.text, secondaryLine: secondaryText, track: currentTrack, isPlaying: isPlaying, progress: playbackProgress, nextLineIntervalSec: nextLineIntervalSec)
        } else {
            let isPlaceholder = (currentTrack.title == TrackInfo.placeholder.title)
            let introPrimary = isPlaceholder ? String(localized: "AuraLyrics 即時歌詞") : currentTrack.title
            let firstLineText = currentLyrics.lines.first?.text
            let introSecondary = isPlaceholder ? nil : (firstLineText ?? (currentTrack.artist.isEmpty ? nil : currentTrack.artist))

            PiPLyricsEngine.shared.updateLyrics(line: introPrimary, secondaryLine: introSecondary, progress: playbackProgress)
            LiveActivityLyricsEngine.shared.updateLyrics(line: introPrimary, secondaryLine: introSecondary, track: currentTrack, isPlaying: isPlaying, progress: playbackProgress, nextLineIntervalSec: nextLineIntervalSec)
        }
    }

    public func interpolatedPlaybackTimeMs() -> Int {
        let elapsed = isPlaying ? max(0, CACurrentMediaTime() - anchorMediaTime) : 0
        let timeSec = anchorPlaybackTimeSec + elapsed
        return Int(timeSec * 1000) + globalOffsetMs
    }

    public func seek(toMs targetLineTimeMs: Int) {
        guard playbackSource == .appleMusic else { return }
        let rawMs = targetLineTimeMs - globalOffsetMs - currentLyrics.offsetMs
        let targetSec = max(0.0, Double(rawMs) / 1000.0)
        musicPlayer.currentPlaybackTime = targetSec
        currentPlaybackTimeSec = targetSec
        anchorPlaybackTimeSec = targetSec
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = targetSec
        if currentTrack.duration > 0 { playbackProgress = min(max(targetSec / currentTrack.duration, 0.0), 1.0) }
        refreshCurrentLineIndex(forceSync: true)
    }

    public func adjustGlobalOffset(byMs: Int) {
        globalOffsetMs += byMs
        refreshCurrentLineIndex(forceSync: true)
    }

    public func resetGlobalOffset() {
        globalOffsetMs = 0
        refreshCurrentLineIndex(forceSync: true)
    }

    public func applyCustomLyrics(_ lyrics: SyncedLyrics) {
        currentLyrics = lyrics
        refreshCurrentLineIndex(forceSync: true)
    }
    
    // MARK: - 翻譯功能
    public func translateCurrentLyrics() async {
        guard !isTranslatingLyrics else { return }
        isTranslatingLyrics = true
        defer { isTranslatingLyrics = false }
        
        var updatedLines = currentLyrics.lines
        var hasChanges = false
        
        for i in 0..<updatedLines.count {
            if let existingTrans = updatedLines[i].translation, !existingTrans.isEmpty { continue }
            let originalText = updatedLines[i].text
            if originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            
            if let translated = await TranslationService.shared.translateToIndonesian(text: originalText) {
                updatedLines[i].translation = translated
                hasChanges = true
                var tempLyrics = currentLyrics
                tempLyrics.lines = updatedLines
                self.currentLyrics = tempLyrics
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        if hasChanges { print("Semua lirik berhasil diterjemahkan ke Bahasa Indonesia.") }
    }
}
