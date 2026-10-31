import ActivityKit
import WidgetKit
import SwiftUI

@main
struct AuraLyricsWidgetBundle: WidgetBundle {
    var body: some Widget {
        AuraLyricsLiveActivityWidget()
    }
}

public struct AuraLyricsLiveActivityWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            // 鎖定畫面與 StandBy 橫向模式視圖
            LockScreenLyricsView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // 展開視圖 (Expanded Presentation)
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        ArtworkOrIconView(artworkPath: context.state.artworkPath, size: 18)
                        Text(context.state.trackTitle)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 8)
                    .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.artistName)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundColor(Color(white: 0.7))
                        .lineLimit(1)
                        .padding(.trailing, 8)
                        .padding(.top, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        // 主歌詞行
                        Text(context.isStale ? String(localized: "App 已暫停或關閉 · 點擊恢復同步") : context.state.currentLine)
                            .id(context.state.currentLine)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(context.isStale ? Color(white: 0.6) : .white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .transition(.push(from: .bottom))
                            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: context.state.currentLine)

                        // 雙語翻譯或下一句預覽行
                        if !context.isStale, let secondary = context.state.secondaryLine, !secondary.isEmpty {
                            Text(secondary)
                                .id(secondary)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(Color.pink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .transition(.push(from: .bottom))
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            } compactLeading: {
                CompactLeadingView(
                    compactStyle: context.state.compactStyle,
                    artworkPath: context.state.artworkPath
                )
            } compactTrailing: {
                CompactTrailingView(
                    currentLine: context.isStale ? String(localized: "已暫停") : context.state.currentLine
                )
            } minimal: {
                ArtworkOrIconView(artworkPath: context.state.artworkPath, size: 14)
            }
            .keylineTint(Color.pink.opacity(0.5))
        }
    }
}

// MARK: - 縮圖或圖示共用視圖
struct ArtworkOrIconView: View {
    let artworkPath: String?
    let size: CGFloat

    var body: some View {
        if let path = artworkPath,
           let uiImage = UIImage(contentsOfFile: path) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.85, weight: .bold))
                .foregroundColor(.pink)
        }
    }
}

// MARK: - 緊湊 Leading 視圖
struct CompactLeadingView: View {
    let compactStyle: String
    let artworkPath: String?

    var body: some View {
        if compactStyle == DynamicIslandCompactStyle.artworkAndText.rawValue {
            ArtworkOrIconView(artworkPath: artworkPath, size: 16)
                .padding(.leading, 4)
        } else if compactStyle == DynamicIslandCompactStyle.iconAndText.rawValue {
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.pink)
                .padding(.leading, 4)
        }
    }
}

// MARK: - 緊湊 Trailing 視圖
struct CompactTrailingView: View {
    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth
    let currentLine: String

    var body: some View {
        if isLimitedInWidth {
            Image(systemName: "waveform")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.pink)
                .padding(.trailing, 4)
        } else {
            Text(currentLine)
                .id(currentLine)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.trailing, 4)
                .transition(.push(from: .bottom))
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: currentLine)
        }
    }
}

// MARK: - 鎖定畫面歌詞視圖 (Liquid Glass 主題自適應)
struct LockScreenLyricsView: View {
    let context: ActivityViewContext<LyricsActivityAttributes>
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isLight = context.state.isLightMode || (colorScheme == .light)
        
        // Warna teks dinamis
        let primaryText = isLight ? Color.black : Color.white
        let secondaryText = isLight ? Color(white: 0.35) : Color.white.opacity(0.68)
        let subtleText = isLight ? Color(white: 0.50) : Color.white.opacity(0.45)
        
        // Efek Kaca (Liquid Glass)
        let glassTint = isLight ? Color.white.opacity(0.65) : Color.black.opacity(0.45)

        VStack(alignment: .leading, spacing: 6) {
            // 頂部歌曲資訊列
            HStack(spacing: 8) {
                ArtworkOrIconView(artworkPath: context.state.artworkPath, size: 18)

                Text("\(context.state.trackTitle) · \(context.state.artistName)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(secondaryText)
                    .lineLimit(1)

                Spacer()

                Text("AuraLyrics")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(subtleText)
            }
            .frame(height: 18)

            // 歌詞區塊
            VStack(alignment: .leading, spacing: 4) {
                Text(context.isStale ? String(localized: "App 已暫停或關閉 · 點擊開啟 AuraLyrics 恢復同步") : context.state.currentLine)
                    .id(context.state.currentLine)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(context.isStale ? subtleText : primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
                    .transition(.push(from: .bottom))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: context.state.currentLine)

                if !context.isStale, let secondary = context.state.secondaryLine, !secondary.isEmpty {
                    Text(secondary)
                        .id(secondary)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(Color.pink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .transition(.push(from: .bottom))
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, minHeight: 108, maxHeight: 108, alignment: .topLeading)
        // Terapkan efek Liquid Glass transparan
        .activityBackgroundTint(glassTint)
        // Tambahkan garis tepi kaca yang tipis
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isLight ? Color.white.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1)
        )
        .activitySystemActionForegroundColor(isLight ? Color.black : Color.white)
    }
}
