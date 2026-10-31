import SwiftUI

struct PlaybackSettingsView: View {
    @ObservedObject var monitor = AppleMusicMonitor.shared
    @ObservedObject var authManager = SpotifyAuthManager.shared
    
    @State private var isLoggingIn = false
    @State private var loginError: String? = nil

    var body: some View {
        Form {
            // MARK: - Pilihan Sumber Pemutar
            Section {
                Picker("Sumber pemutar", selection: $monitor.playbackSource) {
                    Label("Apple Music", systemImage: "music.note")
                        .tag(PlaybackSource.appleMusic)
                    
                    Label("Spotify", systemImage: "waveform")
                        .tag(PlaybackSource.spotify)
                    
                    Label("System (YouTube Music, dll)", systemImage: "antenna.radiowaves.left.and.right")
                        .tag(PlaybackSource.system)
                }
                .pickerStyle(.inline)
            } header: {
                Text("Sumber Pemutar")
            } footer: {
                Text("Pilih 'System' jika kamu memutar lagu dari YouTube Music, SoundCloud, atau aplikasi lain yang tampil di Control Center.")
            }
            
            // MARK: - Menu Khusus Spotify
            if monitor.playbackSource == PlaybackSource.spotify {
                Section {
                    HStack {
                        Text("Status Akun")
                        Spacer()
                        if authManager.isLoggedIn {
                            Text("Terhubung")
                                .foregroundColor(.green)
                                .fontWeight(.medium)
                        } else {
                            Text("Belum masuk")
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if authManager.isLoggedIn {
                        Button(role: .destructive) {
                            authManager.logout()
                            monitor.playbackSource = PlaybackSource.appleMusic // Kembali ke default jika logout
                        } label: {
                            Label("Keluar dari Spotify", systemImage: "rectangle.portrait.and.arrow.right")
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
                                Label("Masuk dengan Spotify", systemImage: "person.badge.key.fill")
                                Spacer()
                                if isLoggingIn {
                                    ProgressView()
                                }
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
            
            // MARK: - Informasi Khusus System
            if monitor.playbackSource == PlaybackSource.system {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                            .padding(.top, 2)
                        Text("Aplikasi akan mencoba membaca metadata lagu dari Control Center menggunakan Private API. Fitur ini mungkin tidak berfungsi jika iOS membatasi aksesnya.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Info System")
                }
            }
        }
        .navigationTitle("Sumber Pemutar")
        .navigationBarTitleDisplayMode(.inline)
    }
}
