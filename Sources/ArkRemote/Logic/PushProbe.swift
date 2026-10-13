import Foundation

// 运行自检's push check (Pages/Phone/PhoneDiag.swift SelfCheck, item 4): open one ntfy stream, wait for its `open`
// event, close it. The 8 s is a network timeout, not a view on a timer: here in Logic/ with the other request
// timeouts (ark-native-lint skips Logic/: "no views there: retry delays and timers are not UI"). One stream per
// 运行自检 tap, nothing loops (NoPollingTests).
@MainActor enum PushProbe {
    /// ms until the stream's `open` event, or nil after 8 s.
    static func openMs(topic: String) async -> Int? {
        let t0 = nowMs()
        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            let done = OnceFlag()
            var stream: NtfyStream?
            stream = NtfyStream(topics: topic, since: "\(Int(t0 / 1000))") { e in
                if e["event"]?.string == "open", done.take() {
                    stream?.close()
                    cont.resume(returning: Int(nowMs() - t0))
                }
            }
            stream?.open()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if done.take() {
                    stream?.close()
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

/// True for the first caller only.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
