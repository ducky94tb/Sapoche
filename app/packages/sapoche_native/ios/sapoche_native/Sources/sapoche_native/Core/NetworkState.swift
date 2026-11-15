import Foundation

/// What the whole app knows of the network, for code that has no session to ask: the stream cache picks a lower quality
/// by it. Written by `NetworkHealth` (weak) and by the player (what it measured); read from any thread.
final class NetworkState: @unchecked Sendable {
    static let shared = NetworkState()

    private let lock = NSLock()
    private var weakValue = false
    private var bandwidthValue: Int64 = 0
    private var onlineValue = true

    /// The network is too weak for the plain rules: songs are fetched in a lower quality.
    var weak: Bool {
        get { lock.withLock { weakValue } }
        set { lock.withLock { weakValue = newValue } }
    }

    /// The phone reaches the internet, as the system says (`NWPath.status`); true until told otherwise, so that a doubt never
    /// keeps a download from being tried. Written by the platform when the path changes.
    var online: Bool {
        get { lock.withLock { onlineValue } }
        set { lock.withLock { onlineValue = newValue } }
    }

    private var meteredValue = false

    /// The network is paid by the amount or the person asked to spare it (mobile data, the hotspot of another phone: `NWPath.isExpensive`
    /// and `isConstrained`): a picture taller than 1080p waits for another network. Written by the platform when the path changes.
    var metered: Bool {
        get { lock.withLock { meteredValue } }
        set { lock.withLock { meteredValue = newValue } }
    }

    /// What the player last measured the network to carry, in kbps; 0 until it measured.
    var bandwidthKbps: Int64 {
        get { lock.withLock { bandwidthValue } }
        set { lock.withLock { bandwidthValue = newValue } }
    }
}
