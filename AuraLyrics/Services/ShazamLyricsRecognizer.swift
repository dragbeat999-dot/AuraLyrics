import Foundation
import ShazamKit
import AVFoundation
import Combine

@MainActor
public final class ShazamLyricsRecognizer: NSObject, ObservableObject {
    public static let shared = ShazamLyricsRecognizer()
    
    @Published public private(set) var isListening: Bool = false
    @Published public private(set) var statusMessage: String? = nil
    @Published public private(set) var recognizedTitle: String? = nil
    @Published public private(set) var recognizedArtist: String? = nil
    
    private var session: SHManagedSession?
    
    private override init() {
        super.init()
    }
    
    /// Memulai proses dengar lagu (Shazam)
    public func startListening() async {
        guard !isListening else { return }
        
        isListening = true
        statusMessage = "Mendengarkan... (Putar lagu di aplikasi lain)"
        recognizedTitle = nil
        recognizedArtist = nil
        
        let managedSession = SHManagedSession()
        self.session = managedSession
        
        do {
            let result = await managedSession.result()
            
            managedSession.cancel()
            isListening = false
            
            switch result {
            case .match(let match):
                if let item = match.mediaItems.first {
                    let title = item.title ?? ""
                    let artist = item.artist ?? ""
                    
                    if !title.isEmpty {
                        self.recognizedTitle = title
                        self.recognizedArtist = artist
                        self.statusMessage = "Ditemukan: \(title) - \(artist)"
                        
                        await self.searchLyricsForRecognizedSong(title: title, artist: artist)
                    } else {
                        self.statusMessage = "Lagu terdeteksi, tapi metadata tidak lengkap."
                    }
                }
            case .noMatch(_):
                self.statusMessage = "Lagu tidak dikenali. Coba dekatkan speaker."
            case .error(let error, _):
                self.statusMessage = "Error: \(error.localizedDescription)"
            }
        } catch {
            isListening = false
            statusMessage = "Gagal memulai sesi: \(error.localizedDescription)"
        }
    }
    
    /// Fungsi untuk mencari lirik menggunakan LyricsProviderService
    private func searchLyricsForRecognizedSong(title: String, artist: String) async {
        let query = "\(title) \(artist)"
        
        let results = await LyricsProviderService.shared.searchOnlineLyrics(
            query: query,
            targetTitle: title,
            targetArtist: artist,
            durationSec: 0
        )
        
        if let bestLyrics = results.first {
            AppleMusicMonitor.shared.applyCustomLyrics(bestLyrics)
            self.statusMessage = "Lirik berhasil dimuat untuk: \(title)"
        } else {
            self.statusMessage = "Lagu ditemukan, tapi lirik tidak tersedia di database."
        }
    }
}
