import Foundation
import Security

/// Where the scrobbler keeps what it needs: the token in the Keychain, readable once the phone has been unlocked after it
/// started (the app sends while the phone is locked, playing) and not moved to other devices; the queue in a file of the
/// app's own, in a folder that is kept out of the backups. Neither is read by the library backup or the diagnostic report.
final class AppleScrobbleStorage: ScrobbleStorage {
    private let service = "app.sapoche.scrobble"
    private let account: String
    private let file: URL

    /// [account] is the Keychain item: one for each service.
    init(folder: URL, account: String = "listenbrainz") {
        self.account = account
        var folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The folder, not the file: a file written over is a new file, and the folder's mark stays
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try? folder.setResourceValues(excluded)
        file = folder.appendingPathComponent("queue.json")
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    var token: String? {
        get {
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &found)
            guard status == errSecSuccess, let data = found as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue else { return }
            let item = query.merging([
                kSecValueData as String: Data(newValue.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) { $1 }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func loadState() -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    func saveState(_ text: String) {
        // Written whole beside it and moved over, so a phone that dies half way keeps the last good queue
        try? Data(text.utf8).write(to: file, options: .atomic)
    }
}
