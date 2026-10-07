import XCTest
@testable import ArkRemote

/// The app state the link and heartbeat tests touch: Relay.shared, StaminaStore.shared, PhoneLink's clipboard seam and
/// the UserDefaults keys they write. Taken at the start of a test and put back in its `defer`.
@MainActor struct SharedStateGuard {
    static let keys = [Relay.cfgKey, StaminaStore.tokensKey, StaminaStore.cacheKey, PhoneLink.takenKey, Live.hbSeenKey]

    let config: RelayConfig?
    let snap: JSONValue?
    let statusText: String
    let statusState: String
    let tokens: JSONValue?
    let data: StaminaReading?
    let at: Double
    let takenMs: Double
    let cached: Bool
    let fetch: (String, String, [String: String], Data?, Bool) async throws -> (Data, Int)
    let readClipboard: () -> String?
    let defaults: [(String, Any?)]

    init() {
        let r = Relay.shared, s = StaminaStore.shared
        config = r.config
        snap = r.snap
        statusText = r.statusText
        statusState = r.statusState
        tokens = s.tokens
        data = s.data
        at = s.at
        takenMs = s.takenMs
        cached = s.cached
        fetch = s.fetch
        readClipboard = PhoneLink.readClipboard
        defaults = Self.keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    func restore() {
        let r = Relay.shared, s = StaminaStore.shared
        r.config = config
        r.snap = snap
        r.statusText = statusText
        r.statusState = statusState
        s.tokens = tokens
        s.data = data
        s.at = at
        s.takenMs = takenMs
        s.cached = cached
        s.fetch = fetch
        PhoneLink.readClipboard = readClipboard
        for (k, v) in defaults {
            if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    /// Every 森空岛 / 库街区 request fails at once, so the read PhoneLink.open starts never leaves the Mac, and with every
    /// game failed nothing is written to StaminaStore.cacheKey.
    @discardableResult
    static func stubStaminaOffline() -> CallCount {
        let calls = CallCount()
        StaminaStore.shared.fetch = { _, _, _, _, _ in
            calls.add()
            throw AppError("no network in tests")
        }
        return calls
    }

    /// Wait for the `Task { await StaminaStore.shared.refresh(force: true) }` PhoneLink.open leaves behind: give the
    /// main actor a moment to start it (refresh sets `busy` before its first suspension), then wait while it runs.
    static func settleStaminaRefresh() async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
        var waitedMs = 0
        while StaminaStore.shared.busy {
            guard waitedMs < 3000 else { XCTFail("StaminaStore.refresh still busy after 3 s"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
            waitedMs += 10
        }
    }
}

/// How many times a stub was called (from whichever thread calls it).
final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
