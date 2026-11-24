import Foundation
import LocalAuthentication
import Security

enum Auth {
    static func authenticate(reason: String, _ done: @escaping (Bool) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { done(false); return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }
}

enum Keychain {
    struct Entry: Identifiable { var id: String { host + "|" + user }; let host: String; let user: String }

    static func save(host: String, user: String, pass: String) {
        delete(host: host, user: user)
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user,
            kSecValueData as String: Data(pass.utf8)
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(host: String, user: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: user
        ]
        SecItemDelete(q as CFDictionary)
    }

    static func all() -> [Entry] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let arr = out as? [[String: Any]] else { return [] }
        return arr.compactMap {
            guard let h = $0[kSecAttrServer as String] as? String,
                  let u = $0[kSecAttrAccount as String] as? String else { return nil }
            return Entry(host: h, user: u)
        }
    }

    static func credential(host: String) -> (user: String, pass: String)? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? [String: Any],
              let u = d[kSecAttrAccount as String] as? String,
              let data = d[kSecValueData as String] as? Data,
              let p = String(data: data, encoding: .utf8) else { return nil }
        return (u, p)
    }
}
