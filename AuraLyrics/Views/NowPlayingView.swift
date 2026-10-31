import SwiftUI
import MediaPlayer
import UIKit

/// Apple Music 正在播放與即時歌詞同步畫面（iOS 27 原生 Apple HIG 沉浸流光舞台 + 右上角獨立放大 Liquid Glass 雙圓鈕）
struct NowPlayingView: View {
    @ObservedObject var monitor = AppleMusicMonitor.shared
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var liveActivityEngine = LiveActivityLyricsEngine.shared
    
    // --- STATE OBJECT UNTUK SHAZAM ---
    @StateObject private var shazam = ShazamLyricsRecognizer.shared

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSearchSheet = false
    @State private var showFileImporter = false
    @AppStorage("showBilingualLyrics") private var showTranslation = true
    @AppStorage("enableLyricDefocusBlur") private var enableLyricDefocusBlur = true
    
    // TOMBOL TERJEMAHAN
    @AppStorage("enableAutoTranslation") private var enableAutoTranslation = false

    /// 零重繪之可視行索引追蹤器（參考型別，不觸發全視圖 body 刷新）
    @State private var tracker = ViewportTracker()

    /// 焦點歌詞當前是否在螢幕可視範圍內（僅在布林值翻轉時更新 @State）
    @State private var isCurrentLineInViewport: Bool = true

    /// 記錄使用者是否正在手動滑動螢幕（滑動時立即解除模糊，閒置 1.5s 平滑恢復）
    @State private var isUserScrolling: Bool = false
    @State private var scrollIdleTask: Task<Void, Never>? = nil

    /// 快取解碼後之專輯封面圖，避免在 body 內高頻重複解碼 PNG
    @State private var cachedArtworkImage: UIImage? = nil

    /// 當前專輯封面解析出之色彩調色盤（Apple Music 沉浸式流光背景）
    @State private var currentPalette: ArtworkPalette = .fallback

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topTrailing) {
                // MARK: - 內容層：可滾動穿透之歌詞清單
                lyricsScrollView

                // MARK: - 內容頂層：右上角按鈕
                HStack(spacing: 12) {
                    shazamButton // <--- TOMBOL SHAZAM BARU
                    translateButton 
                    pipIndependentButton
                    moreMenuIndependentButton
                }
                .padding(.trailing, 20)
                .padding(.top, 8)
            }
            .background {
                ambientBackdrop
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSearchSheet) {
                LyricsSearchSheet(currentTrack: monitor.currentTrack) { selectedLyrics in
                    monitor.applyCustomLyrics(selectedLyrics)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.text, .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let imported = LyricsProviderService.shared.importLocalLRCFile(
                            url: url,
                            title: monitor.currentTrack.title,
                            artist: monitor.currentTrack.artist
                        ) {
                            monitor.applyCustomLyrics(imported)
                        }
                    }
                }
            }
            .onChange(of: showTranslation) { _, _ in
                monitor.syncExternalEngines()
            }
        }
    }

    // MARK: - Tombol Shazam (Dengar Lagu)
    private var shazamButton: some View {
        let buttonDiameter: CGFloat = 40
        let isListening = shazam.isListening
        
        return Button {
            Task {
                await shazam.startListening()
            }
        } label: {
            ZStack {
                if isListening {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: isListening, activeTint: .blue)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.85))
        .sensoryFeedback(.impact(weight: .medium), trigger: isListening)
        .accessibilityLabel("Dengarkan dan Cari Lirik Lagu")
    }

    // MARK: - Tombol Terjemahan
    private var translateButton: some View {
        let buttonDiameter: CGFloat = 40
        let isTranslating = monitor.isTranslatingLyrics

        return Button {
            enableAutoTranslation.toggle()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if enableAutoTranslation {
                Task { 
                    await monitor.translateCurrentLyrics() 
                }
            }
        } label: {
            ZStack {
                if isTranslating {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "character.book.closed.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white) 
                        .symbolEffect(.bounce, value: enableAutoTranslation)
                }
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: false)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.85)) 
        .sensoryFeedback(.success, trigger: enableAutoTranslation) 
        .accessibilityLabel("Terjemahkan Lirik ke Indonesia")
    }

    // MARK: - Tombol PiP
    private var pipIndependentButton: some View {
        let isPiPOn = pipEngine.isPiPActive || pipEngine.isPiPEnabled
        let buttonDiameter: CGFloat = 40

        return Button {
            pipEngine.togglePiP()
        } label: {
            ZStack {
                Image(systemName: isPiPOn ? "pip.exit" : "pip.enter")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: isPiPOn, activeTint: .pink)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.90))
        .sensoryFeedback(.impact(weight: .medium), trigger: isPiPOn)
        .accessibilityLabel(isPiPOn ? String(localized: "關閉子母畫面 (PiP)") : String(localized: "開啟子母畫面 (PiP)"))
    }

    // MARK: - Tombol Menu
    private var moreMenuIndependentButton: some View {
        let buttonDiameter: CGFloat = 40

        return Menu {
            Toggle(isOn: $showTranslation) {
                Text("雙語歌詞")
            }

            if !envDetector.isLiveContainer {
                Toggle(isOn: Binding(
                    get: { liveActivityEngine.isEnabled },
                    set: { enabled in
                        liveActivityEngine.isEnabled = enabled
                        if enabled {
                            liveActivityEngine.startActivity(track: monitor.currentTrack)
                            monitor.syncExternalEngines()
                        }
                    }
                )) {
                    Text("即時動態與動態島")
                }
            }

            Divider()

            Button {
                showSearchSheet = true
            } label: {
                Label("線上搜尋歌詞", systemImage: "magnifyingglass")
            }

            Button {
                showFileImporter = true
            } label: {
                Label("匯入本地 .lrc", systemImage: "square.and.arrow.down")
            }
        } label: {
            ZStack {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: buttonDiameter, height: buttonDiameter)
            .liquidGlassCircle(isActive: false)
            .contentShape(Circle())
        }
        .buttonStyle(LiquidSpringButtonStyle(scaleAmount: 0.90))
        .accessibilityLabel(String(localized: "更多歌詞操作選項"))
    }

    @ViewBuilder
    private var ambientBackdrop: some View {
        AmbientGradientBackground(
            palette: currentPalette,
            artworkImage: cachedArtworkImage
        )
        .accessibilityHidden(true)
    }

    // MARK: - 中央滾動歌詞清單
    private var lyricsScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 1)
                    .id("LyricsTopAnchor")

                if monitor.currentLyrics.lines.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 42))
                            .foregroundColor(Color.white.opacity(0.45))

                        Text(monitor.isLoadingLyrics ? String(localized: "正在檢索歌詞...") : String(localized: "目前曲目無對應歌詞"))
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.white)

                        Text("可嘗試線上搜尋其他版本，或手動匯入本地 .lrc 檔案")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        HStack(spacing: 12) {
                            Button {
                                showSearchSheet = true
                            } label: {
                                Label("搜尋歌詞", systemImage: "magnifyingglass")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .frame(minHeight: 44)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.pink)

                            Button {
                                showFileImporter = true
                            } label: {
                                Label("匯入 .lrc", systemImage: "square.and.arrow.down")
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .frame(minHeight: 44)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.bordered)
                            .tint(.white)
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 100)
                } else {
                    LazyVStack(spacing: 26) {
                        ForEach(Array(monitor.currentLyrics.lines.enumerated()), id: \.element.id) { index, line in
                            let isCurrent = (index == monitor.currentLineIndex)

                            HStack(alignment: .top, spacing: 0) {
                                VStack(alignment: .leading, spacing: 6) {
                                    if isCurrent {
                                        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !monitor.isPlaying)) { _ in
                                            let currentPlayMs = monitor.interpolatedPlaybackTimeMs()
                                            AppleMusicKaraokeText(
                                                text: line.text,
                                                syllables: line.syllables,
                                                isCurrent: true,
                                                currentPlaybackTimeMs: currentPlayMs,
                                                blurRadius: 0
                                            )
                                        }
                                    } else {
                                        AppleMusicKaraokeText(
                                            text: line.text,
                                            syllables: line.syllables,
                                            isCurrent: false,
                                            currentPlaybackTimeMs: 0,
                                            blurRadius: blurRadius(for: index)
                                        )
                                        .animation(.easeInOut(duration: 0.35), value: blurRadius(for: index))
                                    }

                                    if showTranslation, let trans = line.translation, !trans.isEmpty {
                                        Text(trans)
                                            .font(.system(size: 16, weight: .medium, design: .default))
                                            .foregroundColor(isCurrent ? .pink : Color.white.opacity(0.65))
                                            .blur(radius: isCurrent ? 0 : translationBlurRadius(for: index))
                                            .animation(.easeInOut(duration: 0.35), value: translationBlurRadius(for: index))
                                            .transition(
                                                .asymmetric(
                                                    insertion: .opacity
                                                        .combined(with: .move(edge: .top))
                                                        .combined(with: .scale(scale: 0.9, anchor: .leading)),
                                                    removal: .opacity
                                                )
                                            )
                                    }
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: line.translation)
                                Spacer()
                            }
                            .padding(.horizontal, 20)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                scrollIdleTask?.cancel()
                                scrollIdleTask = nil
                                isUserScrolling = false
                                monitor.seek(toMs: line.timeMs)
                                isCurrentLineInViewport = true
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(index, anchor: .center)
                                }
                            }
                            .onAppear {
                                tracker.visibleIndices.insert(index)
                                checkCurrentLineVisibility()
                            }
                            .onDisappear {
                                tracker.visibleIndices.remove(index)
                                checkCurrentLineVisibility()
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(line.text + (line.translation.map { String(format: String(localized: "，翻譯：%@"), $0) } ?? ""))
                            .accessibilityHint(isCurrent ? String(localized: "目前唱到的歌詞") : String(localized: "點擊跳轉至此句"))
                        }

                        if !monitor.currentLyrics.credits.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("製作團隊")
                                    .font(.system(size: 15, weight: .semibold, design: .default))
                                    .foregroundColor(Color.white.opacity(0.65))
                                    .padding(.bottom, 2)

                                ForEach(Array(monitor.currentLyrics.credits.enumerated()), id: \.offset) { _, credit in
                                    Text(credit)
                                        .font(.system(size: 13, weight: .regular, design: .default))
                                        .foregroundColor(Color.white.opacity(0.42))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 36)
                            .padding(.bottom, 48)
                        }
                    }
                    .padding(.top, 60)
                    .padding(.bottom, 72)
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                if newPhase == .interacting || newPhase == .decelerating {
                    scrollIdleTask?.cancel()
                    scrollIdleTask = nil
                    if !isUserScrolling {
                        isUserScrolling = true
                    }
                } else if newPhase == .idle {
                    scrollIdleTask?.cancel()
                    scrollIdleTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        isUserScrolling = false
                    }
                }
            }
            .onChange(of: monitor.currentLineIndex) { _, newIndex in
                checkCurrentLineVisibility()
                guard let index = newIndex else { return }
                let isVisible = tracker.visibleIndices.contains(index) || index <= 1
                if isVisible && !isUserScrolling {
                    if reduceMotion {
                        proxy.scrollTo(index, anchor: .center)
                    } else {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: monitor.currentTrack) { _, _ in
                scrollToTop(proxy: proxy)
            }
            .onChange(of: monitor.currentLyrics.id) { _, _ in
                scrollToTop(proxy: proxy)
            }
            .onAppear {
                updateCachedArtwork()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    forceScrollToCurrentLine(proxy: proxy, animated: false)
                }
            }
            .onDisappear {
                scrollIdleTask?.cancel()
                scrollIdleTask = nil
            }
            .onChange(of: monitor.currentTrack.artworkData) { _, _ in
                updateCachedArtwork()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        guard !Task.isCancelled else { return }
                        forceScrollToCurrentLine(proxy: proxy, animated: true)
                    }
                }
            }
        }
    }

    // MARK: - Helper Functions

    private func blurRadius(for index: Int) -> CGFloat {
        guard enableLyricDefocusBlur, !reduceTransparency, !isUserScrolling, isCurrentLineInViewport else {
            return 0.0
        }
        guard let current = monitor.currentLineIndex else {
            return 0.0
        }
        return (index == current) ? 0.0 : 2.0
    }

    private func translationBlurRadius(for index: Int) -> CGFloat {
        guard enableLyricDefocusBlur, !reduceTransparency, !isUserScrolling, isCurrentLineInViewport else {
            return 0.0
        }
        guard let current = monitor.currentLineIndex else {
            return 0.0
        }
        return (index == current) ? 0.0 : 1.2
    }

    private func checkCurrentLineVisibility() {
        guard let current = monitor.currentLineIndex else {
            if !isCurrentLineInViewport {
                isCurrentLineInViewport = true
            }
            return
        }
        let isVisible = tracker.visibleIndices.contains(current) || current <= 1
        if isCurrentLineInViewport != isVisible {
            isCurrentLineInViewport = isVisible
        }
    }

    private func updateCachedArtwork() {
        if let data = monitor.currentTrack.artworkData {
            let image = UIImage(data: data)
            cachedArtworkImage = image
            let key = "\(monitor.currentTrack.title)-\(monitor.currentTrack.artist)"
            Task { @MainActor in
                let palette = await ArtworkColorExtractor.shared.extractPalette(from: image, cacheKey: key)
                withAnimation(.easeInOut(duration: 0.8)) {
                    currentPalette = palette
                }
            }
        } else {
            cachedArtworkImage = nil
            withAnimation(.easeInOut(duration: 0.8)) {
                currentPalette = .fallback
            }
        }
    }

    private func forceScrollToCurrentLine(proxy: ScrollViewProxy, animated: Bool = true) {
        guard let currentIndex = monitor.currentLineIndex,
              monitor.currentLyrics.lines.indices.contains(currentIndex) else { return }

        if reduceMotion || !animated {
            proxy.scrollTo(currentIndex, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.40)) {
                proxy.scrollTo(currentIndex, anchor: .center)
            }
        }
    }

    private func scrollToTop(proxy: ScrollViewProxy) {
        tracker.visibleIndices.removeAll()
        if reduceMotion {
            proxy.scrollTo("LyricsTopAnchor", anchor: .top)
        } else {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo("LyricsTopAnchor", anchor: .top)
            }
        }
    }
}

/// 零重繪之可視行索引追蹤器
private final class ViewportTracker {
    var visibleIndices: Set<Int> = []
}
