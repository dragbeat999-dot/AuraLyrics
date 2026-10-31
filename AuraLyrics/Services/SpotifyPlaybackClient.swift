import Foundation
import QuartzCore

/// Cuplikan status pemutaran Spotify pada satu waktu
public struct SpotifyPlaybackSnapshot {
    public let trackID: String
    public let title: String
    public let artist: String
    public let album: String
    public let durationSec: TimeInterval
    public let progressSec: TimeInterval
    public let isPlaying: Bool
    public let artworkURL: URL?
}

@MainActor
public final class SpotifyPlaybackClient {
    public static let shared = SpotifyPlaybackClient()
    private init() {}

    // MARK: - Model respons Spotify
    private struct CurrentlyPlayingResponse: Decodable {
        let isPlaying: Bool?
        let progressMs: Int?
        let item: Item?

        struct Item: Decodable {
            let id: String?
            let name: String
            let type: String?
            let durationMs: Int?
            let artists: [Artist]?
            let album: Album?
        }

        struct Artist: Decodable {
            let name: String
        }

        struct Album: Decodable {
            let name: String?
            let images: [Image]?
        }

        struct Image: Decodable {
            let url: String
            let width: Int?
        }
    }

    // MARK: - API publik
    /// Mengembalikan nil bila tidak ada lagu aktif (204), iklan, atau podcast.
    public func fetchCurrentlyPlaying() async throws -> SpotifyPlaybackSnapshot? {
        do {
            return try await requestOnce(forceRefresh: false)
        } catch SpotifyError.http(401) {
            return try await requestOnce(forceRefresh: true)
        }
    }

    // MARK: - Internal
    private func requestOnce(forceRefresh: Bool) async throws -> SpotifyPlaybackSnapshot? {
        let token = try await SpotifyAuthManager.shared.validAccessToken(forceRefresh: forceRefresh)

        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        let t0 = CACurrentMediaTime()
        let (data, response) = try await URLSession.shared.data(for: request)
        let t1 = CACurrentMediaTime()

        guard let http = response as? HTTPURLResponse else { throw SpotifyError.http(-1) }

        switch http.statusCode {
        case 200:
            break
        case 204:
            return nil
        case 429:
            let retry = TimeInterval(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            throw SpotifyError.rateLimited(retry)
        default:
            throw SpotifyError.http(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try decoder.decode(CurrentlyPlayingResponse.self, from: data)

        guard let item = body.item, (item.type ?? "track") == "track" else {
            return nil
        }

        let artists = (item.artists ?? []).map { $0.name }.joined(separator: ", ")
        let isPlaying = body.isPlaying ?? false

        var progress = Double(body.progressMs ?? 0) / 1000.0
        if isPlaying {
            // Kompensasi keterlambatan jaringan (setengah waktu bolak-balik)
            progress += max(0, t1 - t0) / 2.0
        }

        let images = item.album?.images ?? []
        let bestImage = images.min(by: { abs(($0.width ?? 0) - 300) < abs(($1.width ?? 0) - 300) })
        let artworkURL = bestImage.flatMap { URL(string: $0.url) }

        return SpotifyPlaybackSnapshot(
            trackID: item.id ?? "\(item.name)|\(artists)",
            title: item.name,
            artist: artists,
            album: item.album?.name ?? "",
            durationSec: Double(item.durationMs ?? 0) / 1000.0,
            progressSec: progress,
            isPlaying: isPlaying,
            artworkURL: artworkURL
        )
    }
}
