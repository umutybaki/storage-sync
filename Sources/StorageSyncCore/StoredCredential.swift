import Foundation

/// One saved set of provider keys, described without its secret.
///
/// The keys themselves live in the macOS Keychain under `keychainReference` and
/// nowhere else. Everything in this type is deliberately safe to keep in
/// SQLite, send over XPC, and draw on screen: the name the user chose, dates,
/// and a masked form of the access key ID.
///
/// Several syncs can point at the same credential. That is the whole reason it
/// exists as its own record rather than a field on a connection: replacing an
/// expired key once fixes every sync that uses it, and adding a second sync to
/// the same account asks for nothing that was already typed in.
public struct StoredCredential: Codable, Hashable, Sendable, Identifiable {
    public let id: CredentialID
    /// What the user calls this set of keys — "Personal AWS", "Work".
    public var name: String
    /// The access key ID with its middle removed, the way AWS's own console
    /// shows it. It is an identifier rather than a secret, and only part of one
    /// is kept, so a saved credential can be told apart in a menu without the
    /// database ever holding anything that grants access.
    ///
    /// Optional because a credential adopted from a build that predates this
    /// store is recorded before its Keychain item has been read, and that read
    /// is allowed to fail rather than block the upgrade.
    public var accessKeySummary: String?
    /// Temporary credentials expire, which is worth saying on screen next to
    /// keys that do not. The token itself never leaves the Keychain.
    public var hasSessionToken: Bool
    /// The Keychain account holding the secret. Fixed for the life of the
    /// credential: connections reference the same string, so changing it would
    /// silently detach every sync using this credential from its keys.
    public let keychainReference: String
    public let createdAt: Date
    /// When the keys were last replaced. Renaming deliberately does not move
    /// it — the question this answers is how old the secret is.
    public var keysUpdatedAt: Date

    public init(
        id: CredentialID = CredentialID(),
        name: String,
        accessKeySummary: String? = nil,
        hasSessionToken: Bool = false,
        keychainReference: String? = nil,
        createdAt: Date = Date(),
        keysUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.accessKeySummary = accessKeySummary
        self.hasSessionToken = hasSessionToken
        self.keychainReference = keychainReference ?? Self.reference(for: id)
        self.createdAt = createdAt
        self.keysUpdatedAt = keysUpdatedAt
    }

    /// Where a newly created credential keeps its secret. Prefixed so it cannot
    /// collide with the bare connection UUIDs older builds used as Keychain
    /// accounts, which stay valid and are adopted as they are.
    public static func reference(for id: CredentialID) -> String {
        "credential.\(id.rawValue.uuidString)"
    }

    /// `AKIA…7QX4`, or nothing when the key is too short to show part of it
    /// without effectively showing all of it.
    public static func summary(forAccessKeyID accessKeyID: String) -> String? {
        let key = accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.count >= 12 { return "\(key.prefix(4))…\(key.suffix(4))" }
        if key.count >= 6 { return "…\(key.suffix(3))" }
        return nil
    }

    /// Names are shown in menus and written to the Keychain item's label, so
    /// they are trimmed and bounded. The cap is far above any name worth
    /// typing and only exists to stop a pasted document becoming one.
    public static func normalizedName(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    /// Used only where StorageSync picks a name itself, adopting credentials
    /// from an older build. A name the user typed is rejected as a duplicate
    /// instead, because silently saving "Work 2" is not what they asked for.
    public static func uniqueName(_ desired: String, avoiding taken: some Sequence<String>) -> String {
        let base = normalizedName(desired).isEmpty ? "Credentials" : normalizedName(desired)
        let existing = Set(taken.map { $0.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }
        var index = 2
        while existing.contains("\(base) \(index)".lowercased()) { index += 1 }
        return "\(base) \(index)"
    }
}
