import Foundation
import MachO
import Security

/// Accepts XPC connections only from the StorageSync app that ships in the same
/// bundle as this agent.
struct XPCPeerValidator {
    private let mainExecutableURL: URL

    init?() {
        // launchd starts a bundled `BundleProgram` with a *relative* argv[0]
        // ("Contents/Helpers/StorageSyncAgent") and a working directory of "/",
        // so argv[0] cannot locate the app. Ask the kernel for the real path
        // instead; that is correct however the agent was started.
        guard let helperURL = Self.executableURL() else { return nil }
        mainExecutableURL = helperURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Contents/MacOS/StorageSync", isDirectory: false)
    }

    func accepts(processIdentifier: pid_t) -> Bool {
        // The requirement is read for each connection rather than captured once
        // at startup. An app updated in place gets a new code identity, and a
        // pinned requirement would reject the very app this agent belongs to
        // until the agent restarted — which would interrupt whatever it is
        // transferring. Reading it fresh is not weaker: it still names the
        // sibling app inside this bundle, which nothing without write access to
        // the bundle can replace.
        guard let requirement = currentRequirement() else { return false }
        var peerCode: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &peerCode) == errSecSuccess,
              let peerCode else { return false }
        return SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess
    }

    private func currentRequirement() -> SecRequirement? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(mainExecutableURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    private static func executableURL() -> URL? {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }
}
