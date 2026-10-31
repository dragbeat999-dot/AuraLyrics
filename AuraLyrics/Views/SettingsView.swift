import SwiftUI
import ActivityKit

/// Halaman Pengaturan Utama AuraLyrics
struct SettingsView: View {
    @ObservedObject var envDetector = RuntimeEnvironmentDetector.shared
    @ObservedObject var pipEngine = PiPLyricsEngine.shared
    @ObservedObject var keepAlive = BackgroundKeepAliveManager.shared
    @ObservedObject var pipVM = PiPLyricsViewModel.shared
    @ObservedObject var musicMonitor = AppleMusicMonitor.shared
    @ObservedObject var lyricsProvider = LyricsProviderService.shared

    @State private var showResetCacheAlert = false
    @State private var cacheClearedToast = false
    @AppStorage("enableLyricDefocusBlur") private var enableLyricDefocusBlur = true

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 1. SUMBER PEMUTAR
                Section {
                    NavigationLink {
                        PlaybackSettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note.tv")
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.pink)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sumber Pemutar")
                                    .font(.body)
                                Text(playbackSourceName)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Sumber Pemutar")
                } footer: {
                    Text("Pilih dari mana lagu diputar (Apple Music, Spotify, atau System untuk YouTube Music/SoundCloud).")
                }

                // MARK: - 2. PICTURE IN PICTURE (PiP)
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        PiPLyricsView(viewModel: pipVM)
                            .frame(height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
                    }
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    Toggle(isOn: Binding(
                        get: { pipEngine.isPiPEnabled },
                        set: { enable in
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            if enable { pipEngine.startPiP() } else { pipEngine.stopPiP() }
                        }
                    )) {
                        Label {
                            Text("Aktifkan Picture in Picture (PiP)")
                        } icon: {
                            Image(systemName: "pip.fill")
                                .foregroundColor(.pink)
                        }
                    }
                } header: {
                    Text("Picture in Picture (PiP)")
                } footer: {
                    Text("Menampilkan lirik dalam jendela mengambang yang bisa dipindah-pindahkan.")
                }

                // MARK: - 3. LIVE ACTIVITY & DYNAMIC ISLAND
                Section {
                    NavigationLink {
                        LiveActivitySettingsView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Live Activity & Dynamic Island")
                                    .font(.body)
                                Text(LiveActivityLyricsEngine.shared.isEnabled ? "Aktif" : "Nonaktif")
                                    .font(.caption)
                                    .foregroundColor(LiveActivityLyricsEngine.shared.isEnabled ? .green : .secondary)
                            }
                        }
                    }
                } header: {
                    Text("Live Activity")
                } footer: {
                    Text("Menampilkan lirik real-time di Dynamic Island dan Lock Screen saat kamu memutar lagu.")
                }

                // MARK: - 4. SUMBER LIRIK
                Section {
                    NavigationLink {
                        LyricsSourcePriorityView()
                    } label: {
                        Label {
                            Text("Prioritas Pencarian Lirik")
                        } icon: {
                            Image(systemName: "arrow.up.arrow.down.square.fill")
                                .foregroundColor(.orange)
                        }
                    }
                } header: {
                    Text("Sumber Lirik")
                } footer: {
                    Text("Atur urutan penyedia lirik (Musixmatch, NetEase, LRCLIB, PetitLyrics) sesuai preferensi kamu.")
                }

                // MARK: - 5. TAMPILAN & VISUAL
                Section {
                    Toggle(isOn: $enableLyricDefocusBlur) {
                        Label {
                            Text("Efek Blur Lirik Non-Fokus")
                        } icon: {
                            Image(systemName: "wind")
                                .foregroundColor(.blue)
                        }
                    }
                } header: {
                    Text("Tampilan & Visual")
                } footer: {
                    Text("Saat aktif, lirik di luar fokus akan tampak buram untuk menyorot lirik yang sedang diputar. Nonaktifkan untuk menghemat baterai.")
                }

                // MARK: - 6. SINKRONISASI WAKTU
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label {
                                Text("Delay Lirik Global")
                            } icon: {
                                Image(systemName: "metronome.fill")
                                    .foregroundColor(.pink)
                            }
                            Spacer()
                            Text(String(format: String(localized: "%+.1f 秒"), Double(musicMonitor.globalOffsetMs) / 1000.0))
                                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                                .foregroundColor(musicMonitor.globalOffsetMs == 0 ? .secondary : .pink)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }

                        HStack(spacing: 10) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                musicMonitor.adjustGlobalOffset(byMs: -100)
                            } label: {
                                Text("-0.1s")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                musicMonitor.resetGlobalOffset()
                            } label: {
                                Text("Reset")
                                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.bordered)
                            .tint(.secondary)

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                musicMonitor.adjustGlobalOffset(byMs: 100)
                            } label: {
                                Text("+0.1s")
                                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Sinkronisasi Waktu")
                } footer: {
                    Text("Delay ini berlaku untuk semua lagu. Nilai positif = lirik muncul lebih cepat, negatif = lebih lambat.")
                }

                // MARK: - 7. DIAGNOSTIK
                Section {
                    diagnosticRow(
                        icon: "shippingbox.fill",
                        title: "Lingkungan Runtime",
                        value: envDetector.isLiveContainer ? "LiveContainer" : "Sideload Native",
                        color: envDetector.isLiveContainer ? .orange : .green
                    )
                    diagnosticRow(
                        icon: "waveform",
                        title: "Live Activity (ActivityKit)",
                        value: envDetector.areLiveActivitiesAvailable ? "Didukung" : "Terbatas",
                        color: envDetector.areLiveActivitiesAvailable ? .green : .orange
                    )
                    diagnosticRow(
                        icon: "pip",
                        title: "Picture in Picture (PiP)",
                        value: pipEngine.isPiPPossible ? "Didukung" : "Tidak Didukung",
                        color: pipEngine.isPiPPossible ? .green : .red
                    )
                    diagnosticRow(
                        icon: "bolt.shield.fill",
                        title: "Background Keep-Alive",
                        value: keepAlive.isRunning ? "Berjalan" : "Dijeda",
                        color: keepAlive.isRunning ? .green : .secondary
                    )
                } header: {
                    Text("Diagnostik Lingkungan")
                } footer: {
                    Text("Jika kamu menggunakan LiveContainer, sistem iOS mungkin membatasi fitur Live Activity.")
                }

                // MARK: - 8. BACKGROUND KEEP-ALIVE
                Section {
                    Toggle(isOn: Binding(
                        get: { keepAlive.isRunning },
                        set: { enable in
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if enable { keepAlive.startKeepAlive() } else { keepAlive.stopKeepAlive() }
                        }
                    )) {
                        Label {
                            Text("Aktifkan Background Keep-Alive")
                        } icon: {
                            Image(systemName: "bolt.shield.fill")
                                .foregroundColor(.pink)
                        }
                    }
                } header: {
                    Text("Background Keep-Alive")
                } footer: {
                    Text("Menjaga aplikasi tetap berjalan di latar belakang agar lirik selalu tersinkronisasi.")
                }

                // MARK: - 9. PENYIMPANAN
                Section {
                    Button(role: .destructive) {
                        showResetCacheAlert = true
                    } label: {
                        Label {
                            Text("Hapus Semua Cache Lirik")
                        } icon: {
                            Image(systemName: "trash.fill")
                        }
                        .frame(minHeight: 36)
                    }
                } header: {
                    Text("Penyimpanan")
                } footer: {
                    Text("Menghapus cache akan membuat aplikasi mengunduh ulang lirik saat lagu diputar kembali.")
                }

                // MARK: - 10. TENTANG
                Section {
                    HStack {
                        Label {
                            Text("Versi Aplikasi")
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.blue)
                        }
                        Spacer()
                        Text(appVersionString)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Label {
                            Text("Sumber Lirik")
                        } icon: {
                            Image(systemName: "music.note.list")
                                .foregroundColor(.pink)
                        }
                        Spacer()
                        Text("Musixmatch, NetEase, LRCLIB, PetitLyrics")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    HStack {
                        Label {
                            Text("Lisensi")
                        } icon: {
                            Image(systemName: "doc.text.fill")
                                .foregroundColor(.orange)
                        }
                        Spacer()
                        Text("MPL-2.0")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Tentang AuraLyrics")
                } footer: {
                    Text("AuraLyrics adalah aplikasi open-source pihak ketiga untuk menampilkan lirik. Semua hak cipta lirik, terjemahan, dan metadata milik pemiliknya masing-masing.")
                }
            }
            .navigationTitle("Pengaturan")
            .alert("Hapus Semua Cache?", isPresented: $showResetCacheAlert) {
                Button("Batal", role: .cancel) {}
                Button("Hapus", role: .destructive) {
                    clearAllCache()
                }
            } message: {
                Text("Tindakan ini akan menghapus semua cache lirik lokal. Lirik akan diunduh ulang saat lagu diputar kembali.")
            }
            .overlay(alignment: .bottom) {
                if cacheClearedToast {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Cache berhasil dihapus")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .liquidGlassCapsule()
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: cacheClearedToast)
        }
    }

    // MARK: - Helper: Nama Sumber Pemutar
    private var playbackSourceName: String {
        switch musicMonitor.playbackSource {
        case .appleMusic: return "Apple Music"
        case .spotify: return "Spotify"
        case .system: return "System (YouTube Music, dll)"
        }
    }

    // MARK: - Helper: Baris Diagnostik
    @ViewBuilder
    private func diagnosticRow(icon: String, title: String, value: String, color: Color) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundColor(.pink)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: color == .green ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundColor(color)
                Text(value)
                    .fontWeight(.medium)
                    .foregroundColor(color)
            }
            .font(.subheadline)
        }
    }

    // MARK: - Fungsi Hapus Cache
    private func clearAllCache() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        LyricsProviderService.shared.clearAllCache()
        cacheClearedToast = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            cacheClearedToast = false
        }
    }

    // MARK: - Versi Aplikasi
    private var appVersionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (Build \(build))"
    }
}
