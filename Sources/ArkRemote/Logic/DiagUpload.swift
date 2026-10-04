// The diagnostic bucket upload shared by 诊断记录 (件 C), crash-rec and fluency-rec.
//
// Ported from maa-automation/web: seg-frames-logger.js 件 C (:502-519), crash-rec.js flush() and fluency-rec.js put().
// All three PUT one JSON object anonymously into the bucket ark-diag-1315873325 (ap-shanghai): the bucket policy admits
// an anonymous name/cos:PutObject on diag/* only (read / list / anything else 403, seg-frames-logger.js:64-66), so the
// app holds no key, exactly like the page. The bucket's CORS rule only matters to a browser; a native request sends no
// Origin. Every key is a timestamp + random hex and `x-cos-forbid-overwrite: true` keeps a key collision from replacing
// an earlier record: the same key twice answers 409 FileAlreadyExists, which means an earlier try already landed.
// localStorage["ark-diag-bucket"] (the web's test-bench override) is UserDefaults "ark-diag-bucket" here.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if !os(Android) && canImport(UIKit)
import UIKit
#endif

enum DiagUpload {
    /// seg-frames-logger.js COS_BASE / crash-rec.js / fluency-rec.js BUCKET default.
    static let defaultBucket = "https://ark-diag-1315873325.cos.ap-shanghai.myqcloud.com"

    /// The bucket URL without a trailing slash: the override when one is set, else the default.
    static var bucket: String {
        var v = (UserDefaults.standard.string(forKey: "ark-diag-bucket") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if v.isEmpty { v = defaultBucket }
        while v.hasSuffix("/") { v.removeLast() }
        return v
    }

    /// PUT `data` as `<bucket>/<name>`; `name` is the whole object key, `diag/...` included.
    /// true = landed (2xx) or already there (409); false = offline / refused / anything else.
    static func put(name: String, data: Data) async -> Bool {
        guard let url = URL(string: bucket + "/" + name) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("true", forHTTPHeaderField: "x-cos-forbid-overwrite")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 30
        req.httpBody = data
        #if !os(Android) && canImport(UIKit)
        // fetch keepalive (fluency-rec.js flush on hide): going to the background must not cut the PUT off
        let bg = await MainActor.run { UIApplication.shared.beginBackgroundTask(withName: "diag-upload", expirationHandler: nil) }
        defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }
        #endif
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)   // the same call as Net.swift httpFetch (corelibs has it)
            guard let h = resp as? HTTPURLResponse else { return false }
            let ok = (200..<300).contains(h.statusCode) || h.statusCode == 409
            if !ok { logger.info("diag upload: \(h.statusCode) for \(name)") }
            return ok
        } catch {
            logger.info("diag upload: \(error.localizedDescription)")
            return false
        }
    }
}
