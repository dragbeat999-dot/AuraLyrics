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
                }
                .pickerStyle(.inline)
            } header: {
                Text("Sumber pemutar")
            } footer: {
                Text("Pilih sumber lagu yang sedang kamu putar (Apple Music atau Spotify).")
            }
            
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
                            monitor.playbackSource = .appleMusic
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
                            Text(error).font(.footnote).foregroundColor(.red)
                        }
                    }
                } header: {
                    Text("Akun Spotify")
                } footer: {
                    Text("Hanya izin baca lagu yang sedang diputar. Spotify harus sedang memutar lagu di perangkat mana pun.")
                }
            }
        }
        .navigationTitle("Sumber Pemutar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
