import Foundation
import Security

/// アプリと共有拡張で共有するもの（App Group）。
/// - UserDefaults（App Group）: DEBUG のつなぎ先の上書きだけ
/// - Keychain（App Group をアクセスグループに）: Access のサービストークン。**ソースにも UserDefaults にも置かない**
enum AppGroup {
    static let id = "group.jp.kechiiiiin.tayori"
    static let defaults: UserDefaults = UserDefaults(suiteName: id) ?? .standard
}

/// Keychain の汎用パスワード1項目（nobu-ios と同じ作り）。App Group をアクセスグループにして共有拡張からも読む。
/// アクセシビリティは AfterFirstUnlockThisDeviceOnly（バックアップに乗らない）
struct KeychainSecret {
    private static let service = "jp.kechiiiiin.tayori"
    let account: String

    private func base(group: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        if group { q[kSecAttrAccessGroup as String] = AppGroup.id }
        return q
    }

    func save(_ value: String) throws {
        SecItemDelete(base(group: true) as CFDictionary)
        SecItemDelete(base(group: false) as CFDictionary)
        guard !value.isEmpty else { return } // 空文字は削除
        var add = base(group: true)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // 署名なしのシミュレータ向けビルドなど、アクセスグループの entitlement が無いとき
            add.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain への保存に失敗 (status=\(status))"])
        }
    }

    func load() -> String? {
        for group in [true, false] {
            var q = base(group: group)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    var isStored: Bool { load() != nil }
}

/// Cloudflare Access のサービストークン（`CF-Access-Client-Id` / `CF-Access-Client-Secret`）
/// 読む順: Keychain（App Group・設定画面や tmp/ から入れた上書き値）→ ビルドに埋め込んだ値（Info.plist の TayoriAccessClientID/Secret。
/// `make archive` がビルドする Mac のキーチェーンから入れる。Debug・シミュレータのビルドでは空）
enum AccessTokenStore {
    static let clientID = KeychainSecret(account: "cf-access-client-id")
    static let clientSecret = KeychainSecret(account: "cf-access-client-secret")

    private static func embedded(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // 未設定のビルドでは "$(TAYORI_ACCESS_CLIENT_ID)" がそのまま残ることもあるので除く
        return v.isEmpty || v.hasPrefix("$(") ? nil : v
    }

    /// 実際に API で使う値（Keychain → 埋め込み）
    static var idValue: String? { clientID.load() ?? embedded("TayoriAccessClientID") }
    static var secretValue: String? { clientSecret.load() ?? embedded("TayoriAccessClientSecret") }

    static var isComplete: Bool { idValue != nil && secretValue != nil }

    /// 画面に出してよい手がかり（Client ID の先頭だけ。シークレットは出さない）
    static var hint: String? {
        guard let id = idValue else { return nil }
        return String(id.prefix(8)) + "…"
    }
}
