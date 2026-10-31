import SwiftUI

/// Layar pengaturan sumber pemutar (Apple Music / Spotify) dan login Spotify
public struct SpotifySettingsView: View {
    @ObservedObject private var monitor = AppleMusicMonitor.shared
    @ObservedObject private var auth = SpotifyAuthManager.shared

    @State private var isBusy = false
    @State private var errorMessage: String? = nil

    public init() {}

    public var body: some View {
        Form {
            Section {
                Picker("Sumber lagu", selection: $monitor.playbackSource) {
                    Text("Apple Music").tag(PlaybackSource.appleMusic)
                    Text("Spotify").tag(PlaybackSource.spotify)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Sumber pemutar")
            } footer: {
                Text("Pilih Spotify agar lirik mengikuti lagu yang sedang diputar di aplikasi Spotify.")
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(auth.isLoggedIn ? "Terhubung" : "Belum masuk")
                        .foregroundColor(auth.isLoggedIn ? .green : .secondary)
                }

                if auth.isLoggedIn {
                    Button(role: .destructive) {
                        auth.logout()
                    } label: {
                        Text("Keluar dari Spotify")
                    }
                } else {
                    Button {
                        Task { await login() }
                    } label: {
                        if isBusy {
                            ProgressView()
                        } else {
                            Text("Masuk dengan Spotify")
                        }
                    }
                    .disabled(isBusy)
                }

                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                }

                if monitor.playbackSource == .spotify, let status = monitor.spotifyStatusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            } header: {
                Text("Akun Spotify")
            } footer: {
                Text("Hanya izin baca lagu yang sedang diputar. Spotify harus sedang memutar lagu di perangkat mana pun.")
            }
        }
        .navigationTitle("Spotify")
    }

    private func login() async {
        isBusy = true
        errorMessage = nil
        do {
            try await auth.login()
            monitor.refreshSpotifyNow()
        } catch SpotifyError.cancelled {
            // Pengguna membatalkan, tidak perlu pesan
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
    }
}
