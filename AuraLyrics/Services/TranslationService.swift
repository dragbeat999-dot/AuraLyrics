import Foundation

public final class TranslationService {
    public static let shared = TranslationService()
    
    private init() {}
    
    /// Menerjemahkan teks ke Bahasa Indonesia menggunakan API gratis Google Translate
    public func translateToIndonesian(text: String) async -> String? {
        // Jika teks kosong atau hanya berisi spasi, abaikan
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        
        // Encode teks agar aman dikirim lewat URL (mengubah spasi jadi %20, dll)
        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        
        // Endpoint gratis Google Translate (Auto-detect bahasa -> Indonesia)
        let urlString = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=id&dt=t&q=\(encodedText)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10 // Batas waktu 10 detik agar tidak menggantung
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Pastikan server merespons dengan baik (HTTP 200)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            
            // Google Translate mengembalikan format JSON bersarang (Array di dalam Array).
            // Kode ini mengekstrak teks hasil terjemahannya.
            if let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any],
               let firstArray = json.first as? [Any],
               let firstTranslation = firstArray.first as? [Any],
               let translatedText = firstTranslation.first as? String {
                return translatedText
            }
        } catch {
            print("Gagal menerjemahkan: \(error.localizedDescription)")
        }
        
        return nil
    }
}
