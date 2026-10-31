import Foundation
import MediaPlayer
import Combine
import UIKit

/// Sumber lagu yang sedang diputar
public enum PlaybackSource: String, CaseIterable {
    case appleMusic
    case spotify
}

/// Apple Music 系統播放器監聽與即時時間軸推播器（已加入 Spotify 來源支援）
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

    /// 全域歌詞同步時間微調偏移量（毫秒，每首歌共用）
    @Published public var globalOffsetMs: Int {
        didSet {
            UserDefaults.standard.set(globalOffsetMs, forKey: "globalLyricsOffsetMs")
        }
    }

    /// Sumber pemutar yang dipantau (Apple Music atau Spotify)
    @Published public var playbackSource: PlaybackSource {
        didSet {
            guard oldValue != playbackSource else { return }
            UserDefaults.standard.set(playbackSource.rawValue, forKey: "playbackSource")
            handleSourceChanged()
        }
    }

    /// Pesan status/kesalahan terakhir dari Spotify (nil bila normal)
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

    // MARK: - Spotify
    private var spotifyPollTask: Task<Void, Never>? = nil
    private var lastSpotifyTrackID: String = ""
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

        // 進入背景時加固：紀錄背景標記，鎖定高精度時間錨點並立即同步
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

        // App 回到前景時解除背景標記，並主動重新同步播放器狀態
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
                    self.refreshSpotifyNow()
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
                    self.refreshSpotifyNow()
                }
            }
        }
    }

    // MARK: - 啟動監聽與高精度時間軸定時器 (DispatchSourceTimer 前景背景統一驅動)
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

        if playbackSource == .spotify {
            startSpotifyPolling()
        }
    }

    private func stopTimer() {
        timerSource?.cancel()
        timerSource = nil
    }

    public func stopMonitoring() {
        stopTimer()
        spotifyPollTask?.cancel()
        spotifyPollTask = nil
        lyricsFetchTask?.cancel()
        lyricsFetchTask = nil
        musicPlayer.endGeneratingPlaybackNotifications()
    }

    // MARK: - Ganti sumber pemutar (Apple Music <-> Spotify)
    private func handleSourceChanged() {
        spotifyPollTask?.cancel()
        spotifyPollTask = nil
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
        spotifyBackoffSec = 0
        spotifyStatusMessage = nil
        syncExternalEngines()

        // Hanya jalankan ulang bila pemantauan sedang aktif
        guard timerSource != nil else { return }
        switch playbackSource {
        case .appleMusic:
            handleTrackChanged(force: true)
            handlePlaybackStateChanged()
        case .spotify:
            startSpotifyPolling()
        }
    }

    // MARK: - 曲目變更處理 (支援強制刷新與即時清空舊歌詞)
    private func handleTrackChanged(force: Bool = false) {
        guard playbackSource == .appleMusic else { return }

        guard let nowPlaying = musicPlayer.nowPlayingItem else {
            // 背景下若 IPC 讀取為 nil，維持當前歌曲與歌詞，絕不誤清空
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

        let newTrack = TrackInfo(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            artworkData: artworkData,
            genre: genre
        )

        currentTrack = newTrack
        currentLyrics = .empty
        currentLineIndex = nil
        playbackProgress = 0.0

        // 淨化切歌初始播放時間戳：若剛切歌時系統回傳 > 3.0 秒，必定為前一首舊歌之殘留時間，歸零重置
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

                // 核心關鍵修正：當非同步網路請求歌詞完成時（背景可能耗時 1~3 秒），
                // 立即重新取樣當前真實播放進度，校準 anchorPlaybackTimeSec 與音訊 100% 同步！
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
                    // 音樂剛暫停時：若 IPC 時間與本地插值時鐘偏差極小（< 0.4s），保留已平滑前進的 currentPlaybackTimeSec，
                    // 堅決防止換行瞬間因 IPC 延遲把剛頂出的新歌詞扯回上一句！
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

    // MARK: - 時間軸定時器循環 (高精度時鐘平滑推進與智慧防抖校準)
    private func tick() {
        // Mode Spotify memakai jalur terpisah (data dari polling Web API)
        if playbackSource == .spotify {
            tickSpotify()
            return
        }

        let now = CACurrentMediaTime()
        lastTickTimestamp = now

        // 1. 多維度換歌與曲目資訊補齊
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

            // 若先前因串流剛起步未能取得曲目時長，在此自動補齊
            if currentTrack.duration <= 0 && nowPlaying.playbackDuration > 0 {
                let updatedTrack = TrackInfo(
                    title: currentTrack.title,
                    artist: currentTrack.artist,
                    album: currentTrack.album,
                    duration: nowPlaying.playbackDuration,
                    artworkData: currentTrack.artworkData,
                    genre: currentTrack.genre.isEmpty ? (nowPlaying.genre ?? "") : currentTrack.genre
                )
                currentTrack = updatedTrack
            }
        } else if !isInBackground && currentTrack.title != TrackInfo.placeholder.title {
            // 僅在前景時才因 nowPlaying == nil 判定播放器已關閉；背景下忽略 nil 防止誤清空
            handleTrackChanged()
            return
        }

        let playTime = musicPlayer.currentPlaybackTime
        let isPlayTimeValid = !playTime.isNaN && !playTime.isInfinite && playTime >= 0
        let playTimeDelta = isPlayTimeValid ? (playTime - lastPlaybackTimeSec) : 0
        // hasFreshAdvance: 系統回傳了有效且向前遞增的時間戳（排除背景 IPC 凍結、重複舊值或歸零）
        let hasFreshAdvance = isPlayTimeValid && (playTimeDelta > 0.05 && playTimeDelta < 2.0)

        // 2. 播放狀態同步
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

        // 3. 高精度時鐘推進與智慧校準
        if isPlaying {
            let predictedTime = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)

            // 串流緩衝結束首次起跑對齊（剛切歌前幾秒系統 IPC 卡在 0.0，首次回傳有效進度）
            let isInitialStart = (anchorPlaybackTimeSec == 0 && playTime > 0.05 && playTime < 5.0 && hasFreshAdvance)

            // 使用者手動跳轉進度 (Seek：實測時間發生顯著跳躍且與線性推估時間偏差 > 1.0s)
            let playTimeJump = abs(playTime - lastPlaybackTimeSec)
            let isUserSeek = isPlayTimeValid && (playTimeJump > 1.2 && abs(playTime - predictedTime) > 1.0)

            // 長期漂移校準：實測有效時間且偏差 > 1.5 秒時立即平滑對齊
            let hasSignificantDrift = isPlayTimeValid && playTime > 0.5 && (abs(playTime - predictedTime) > 1.5)

            if isUserSeek || isInitialStart || hasSignificantDrift || anchorMediaTime == 0 {
                anchorPlaybackTimeSec = playTime
                anchorMediaTime = now
                currentPlaybackTimeSec = playTime
            } else {
                // 堅定維持本地高精度 CACurrentMediaTime() 線性推進，絕不被未更新的舊值拉扯
                currentPlaybackTimeSec = anchorPlaybackTimeSec + max(0, now - anchorMediaTime)
            }
        } else {
            // 音樂處於暫停狀態：
            // 嚴格凍結當前播放進度！絕不使用 MPMusicPlayerController 暫停時的微幅 IPC 噪聲覆寫時間。
            // 僅在使用者於系統控制中心或鎖定畫面實體拖移進度條（Seek，時間差 > 0.5 秒）時才更新。
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
            // 暫停且無 Seek 時，直接退出 tick，絕不重新觸發 refreshCurrentLineIndex 防止歌詞在邊界來回跳動！
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

    // MARK: - Spotify: polling Web API
    private func startSpotifyPolling() {
        spotifyPollTask?.cancel()
        spotifyPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                await self.pollSpotifyOnce()

                var interval: TimeInterval = self.isPlaying ? 3.0 : 5.0
                // Mendekati akhir lagu: poll lebih sering agar pergantian lagu cepat terdeteksi
                if self.isPlaying && self.currentTrack.duration > 0 {
                    let remaining = self.currentTrack.duration - self.currentPlaybackTimeSec
                    if remaining < 4.0 { interval = 1.0 }
                }
                if self.spotifyBackoffSec > 0 { interval = self.spotifyBackoffSec }

                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// Poll sekarang juga (dipanggil setelah login atau saat aplikasi kembali ke depan)
    public func refreshSpotifyNow() {
        guard playbackSource == .spotify else { return }
        Task { [weak self] in
            await self?.pollSpotifyOnce()
        }
    }

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
            // Jaringan putus / token bermasalah: pertahankan lagu dan lirik yang sedang tampil
            if !Task.isCancelled {
                spotifyStatusMessage = error.localizedDescription
            }
        }
    }

    private func applySpotifySnapshot(_ snapshot: SpotifyPlaybackSnapshot?) {
        let now = CACurrentMediaTime()

        // Tidak ada lagu aktif (204), iklan, atau podcast: anggap berhenti, jangan hapus lirik
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
        if isNewTrack {
            handleSpotifyTrackChanged(snap)
        }

        if snap.isPlaying {
            if isNewTrack || !wasPlaying {
                anchorPlaybackTimeSec = snap.progressSec
            } else {
                // Koreksi bertahap agar lirik tidak melompat karena jitter jaringan
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

        let newTrack = TrackInfo(
            title: snap.title,
            artist: snap.artist,
            album: snap.album,
            duration: snap.durationSec,
            artworkData: nil,
            genre: ""
        )

        currentTrack = newTrack
        currentLyrics = .empty
        currentLineIndex = nil
        playbackProgress = 0.0
        currentPlaybackTimeSec = snap.progressSec
        anchorPlaybackTimeSec = snap.progressSec
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = snap.progressSec
        syncExternalEngines()

        // Unduh sampul album (diperkecil 120x120 seperti jalur Apple Music)
        if let url = snap.artworkURL {
            let trackID = snap.trackID
            Task { [weak self] in
                let data = await Self.downloadArtworkData(from: url)
                guard let self = self, let data = data, self.lastSpotifyTrackID == trackID else { return }
                let t = self.currentTrack
                self.currentTrack = TrackInfo(
                    title: t.title,
                    artist: t.artist,
                    album: t.album,
                    duration: t.duration,
                    artworkData: data,
                    genre: t.genre
                )
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
            self.refreshCurrentLineIndex(forceSync: true)
            self.isLoadingLyrics = false
        }
    }

    private func tickSpotify() {
        let now = CACurrentMediaTime()
        lastTickTimestamp = now

        // Saat jeda: bekukan posisi; perubahan posisi diperbarui oleh polling
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
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.pngData()
    }

    /// 統一依據高精度插值時鐘重新計算當前歌詞行索引，並同步推播至各引擎
    private func refreshCurrentLineIndex(forceSync: Bool = false) {
        let accurateTimeMs = interpolatedPlaybackTimeMs()
        let newIndex = currentLyrics.currentLineIndex(at: accurateTimeMs, globalOffsetMs: 0)

        // 計算距離下一句歌詞的間隔秒數，提供 LiveActivity 動態調整 staleDate
        var nextLineIntervalSec: TimeInterval? = nil
        if let idx = newIndex, idx + 1 < currentLyrics.lines.count {
            let nextStartMs = currentLyrics.lines[idx + 1].timeMs
            nextLineIntervalSec = max(0.5, Double(nextStartMs - accurateTimeMs) / 1000.0)
        }

        // 若音樂已暫停且非手動強制同步 (forceSync == false)，嚴格鎖定歌詞行索引，絕不允許因邊界時間浮動而換行
        if !isPlaying && !forceSync {
            return
        }

        if newIndex != currentLineIndex {
            currentLineIndex = newIndex
            lastHeartbeatTimestamp = CACurrentMediaTime()
            syncExternalEngines(nextLineIntervalSec: nextLineIntervalSec)
        } else if forceSync {
            lastHeartbeatTimestamp = CACurrentMediaTime()
            syncExternalEngines(nextLineIntervalSec: nextLineIntervalSec)
        } else {
            // 長間奏心跳檢測：若歌詞行未改變且已過 4 秒，發送心跳確保 LiveActivity staleDate 持續延長
            let now = CACurrentMediaTime()
            if isPlaying && (now - lastHeartbeatTimestamp >= 4.0) {
                lastHeartbeatTimestamp = now
                LiveActivityLyricsEngine.shared.sendHeartbeat(track: currentTrack)
            }
        }
    }

    /// 主動同步當前歌詞或曲目狀態至 PiP 懸浮窗與 Live Activity 動態島
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

            PiPLyricsEngine.shared.updateLyrics(
                line: current.text,
                secondaryLine: nextLineText,
                progress: playbackProgress
            )
            LiveActivityLyricsEngine.shared.updateLyrics(
                line: current.text,
                secondaryLine: secondaryText,
                track: currentTrack,
                isPlaying: isPlaying,
                progress: playbackProgress,
                nextLineIntervalSec: nextLineIntervalSec
            )
        } else {
            let isPlaceholder = (currentTrack.title == TrackInfo.placeholder.title)
            let introPrimary = isPlaceholder
                ? String(localized: "AuraLyrics 即時歌詞")
                : currentTrack.title
            let firstLineText = currentLyrics.lines.first?.text
            let introSecondary = isPlaceholder ? nil : (firstLineText ?? (currentTrack.artist.isEmpty ? nil : currentTrack.artist))

            PiPLyricsEngine.shared.updateLyrics(
                line: introPrimary,
                secondaryLine: introSecondary,
                progress: playbackProgress
            )
            LiveActivityLyricsEngine.shared.updateLyrics(
                line: introPrimary,
                secondaryLine: introSecondary,
                track: currentTrack,
                isPlaying: isPlaying,
                progress: playbackProgress,
                nextLineIntervalSec: nextLineIntervalSec
            )
        }
    }

    /// 取得高精度插值播放時間（毫秒）
    public func interpolatedPlaybackTimeMs() -> Int {
        let elapsed = isPlaying ? max(0, CACurrentMediaTime() - anchorMediaTime) : 0
        let timeSec = anchorPlaybackTimeSec + elapsed
        return Int(timeSec * 1000) + globalOffsetMs
    }

    // MARK: - 點擊歌詞行跳轉播放進度
    public func seek(toMs targetLineTimeMs: Int) {
        // Mode Spotify: lompat posisi lagu belum didukung (butuh Premium + izin tambahan)
        guard playbackSource == .appleMusic else { return }

        let rawMs = targetLineTimeMs - globalOffsetMs - currentLyrics.offsetMs
        let targetSec = max(0.0, Double(rawMs) / 1000.0)
        musicPlayer.currentPlaybackTime = targetSec
        currentPlaybackTimeSec = targetSec
        anchorPlaybackTimeSec = targetSec
        anchorMediaTime = CACurrentMediaTime()
        lastPlaybackTimeSec = targetSec
        if currentTrack.duration > 0 {
            playbackProgress = min(max(targetSec / currentTrack.duration, 0.0), 1.0)
        }
        refreshCurrentLineIndex(forceSync: true)
    }

    // MARK: - 調整全域共用之時間軸微調偏移量
    public func adjustGlobalOffset(byMs: Int) {
        globalOffsetMs += byMs
        refreshCurrentLineIndex(forceSync: true)
    }

    public func resetGlobalOffset() {
        globalOffsetMs = 0
        refreshCurrentLineIndex(forceSync: true)
    }

    // MARK: - 手動套用自訂歌詞
    public func applyCustomLyrics(_ lyrics: SyncedLyrics) {
        currentLyrics = lyrics
        refreshCurrentLineIndex(forceSync: true)
    }
}
