import Foundation
import UIKit

public final class SystemMediaMonitor {
    public static let shared = SystemMediaMonitor()
    
    // Tipe fungsi dari Private API Apple
    private typealias MRMediaRemoteGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary) -> Void) -> Void
    private var getNowPlayingInfoFunc: MRMediaRemoteGetNowPlayingInfoFunc?
    
    private init() {
        // Memuat Private Framework MediaRemote
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            print("Trik Gagal: Tidak bisa memuat MediaRemote.framework")
            return
        }
        getNowPlayingInfoFunc = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoFunc.self)
    }
    
    /// Mengambil data lagu dari Control Center (YouTube Music, SoundCloud, TikTok, dll)
    public func fetchNowPlaying() async -> (track: TrackInfo, elapsed: TimeInterval, isPlaying: Bool)? {
        guard let getInfo = getNowPlayingInfoFunc else { return nil }
        
        return await withCheckedContinuation { continuation in
            getInfo(DispatchQueue.main) { info in
                let dict = info as NSDictionary
                
                let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
                let artist = dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                let album = dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
                let duration = dict["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0.0
                let elapsed = dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0.0
                let rate = dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0.0
                let isPlaying = rate > 0.0
                
                // Jika tidak ada lagu yang diputar
                if title.isEmpty {
                    continuation.resume(returning: nil)
                    return
                }
                
                let track = TrackInfo(title: title, artist: artist, album: album, duration: duration)
                continuation.resume(returning: (track, elapsed, isPlaying))
            }
        }
    }
}
