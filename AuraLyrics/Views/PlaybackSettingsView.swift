import SwiftUI

struct PlaybackSettingsView: View {
    @ObservedObject var monitor = AppleMusicMonitor.shared
    @ObservedObject var authManager = SpotifyAuthManager.shared
    
    @State private var isLoggingIn = false
    @State private var loginError: String? = nil

    var body: some View {
        Form {
            Section {
                Picker("Sumber pemutar", selection: $monitor.playbackSource) {
                    Text("Apple Music").tag(PlaybackSource.appleMusic)
                    Text("Spotify").tag(PlaybackSource.spotify)
                    Text("System (YT Music, dll)").tag(PlaybackSource.system)
                }
                .pickerStyle(.inline)
            } header: {
                Text("Sumber pemutar")
            } footer: {
                Text("Pilih 'System' jika kamu memutar lagu dari YouTube Music, SoundCloud, atau aplikasi lain yang tampil di Control Center.")
            }
            
            // Menu Khusus Spotify
            if monitor.playbackSource == .spotify {
                Section {
                    HStack {
                        Text("Status")
                        Spacer()
                        if authManager.isLoggedIn {
                            Text("Terhubung").foregroundColor(.green)
                        } else {
                            Text("Belum masuk").foregroundColor(.secondary)
                        }
                    }
                    
                    if authManager.isLoggedIn {
                        Button("Keluar dari Spotify", role: .destructive) {
                            authManager.logout()
                            monitor.playbackSource = .appleMusic // Kembali ke default
                        }
                    } else {
                        Button {
                            isLoggingIn = true
                            loginError = nil
                            Task {
                                do {
                                    try await authManager.login()
                                } catch {
                                    loginError = error.localizedDescription
                                }
                                isLoggingIn = false
                            }
                        } label: {
                            HStack {
                                Text("Masuk dengan Spotify")
                                Spacer()
                                if isLoggingIn { ProgressView() }
                            }
                        }
                        .disabled(isLoggingIn)
                        
                        if let error = loginError {
                            Text(error)
                                .font(.footnote)
                                .foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Akun Spotify")
                } footer: {
                    Text("Hanya izin baca lagu yang sedang diputar. Spotify harus sedang memutar lagu di perangkat mana pun.")
                }
            }
            
            // Informasi Khusus System
            if monitor.playbackSource == .system {
                Section {
                    Text("Aplikasi akan mencoba membaca metadata lagu dari Control Center (Private API).")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Info System")
                }
            }
        }
        .navigationTitle("Sumber Pemutar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
