import AVFoundation
import Foundation

/// Hands Apple's player the playlists kept in [HlsPlaylists]: the player asks for an address of their scheme, and this
/// answers with the text. The pieces those playlists list are https addresses, which the player fetches by itself.
final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "app.sapoche.playlists")
    private let playlists: HlsPlaylists
    private let log: (String) -> Void

    init(playlists: HlsPlaylists, log: @escaping (String) -> Void) {
        self.playlists = playlists
        self.log = log
    }

    /// The request of the player, which is answered from another thread once the playlist is made.
    private struct Pending: @unchecked Sendable {
        let request: AVAssetResourceLoadingRequest
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == HlsPlaylists.scheme else { return false }
        let playlists = playlists
        let log = log
        let pending = Pending(request: loadingRequest)
        // One of the heights of a picture is laid out now, from its index, if the player asks for it only now
        Task {
            do {
                guard let text = try await playlists.resolve(url) else {
                    // Let go to make room for newer ones: the item fails, and whoever plays it loads it again
                    let name = url.lastPathComponent
                    DispatchQueue.main.async { log("the player asked for a playlist that is no longer kept: \(name)") }
                    pending.request.finishLoading(with: URLError(.fileDoesNotExist))
                    return
                }
                Self.answer(pending.request, with: text)
            } catch {
                let name = url.lastPathComponent
                DispatchQueue.main.async { log("could not lay out the playlist \(name): \(error.localizedDescription)") }
                pending.request.finishLoading(with: error)
            }
        }
        return true
    }

    private static func answer(_ loadingRequest: AVAssetResourceLoadingRequest, with text: String) {
        let data = Data(text.utf8)
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = "public.m3u-playlist"
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = false
        }
        if let request = loadingRequest.dataRequest {
            let start = Int(min(max(request.requestedOffset, 0), Int64(data.count)))
            let end = request.requestsAllDataToEndOfResource ? data.count : min(data.count, start + request.requestedLength)
            request.respond(with: data.subdata(in: start..<end))
        }
        loadingRequest.finishLoading()
    }
}
