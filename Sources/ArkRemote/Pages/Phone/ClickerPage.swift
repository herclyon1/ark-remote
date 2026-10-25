#if os(iOS)
import Foundation
import Network
import SwiftUI

// 连点 (iOS only; Android has its own). iOS lets no app tap another app, so the Mac taps: it holds the developer link to
// this iPhone (on Wi-Fi straight over Tailscale, on 4G through the Redmi on this iPhone's hotspot) and sends touches
// down it (~/Money/手机迁移/桌面整理/ios_clicker.py, in the ios-keep agent). This file is the phone's side: one JSON line
// to the Mac and one back, over Network (ATS covers URLSession, not NWConnection, and the Mac speaks no HTTPS).

/// The Mac's answer to one command (ios_clicker.py `answer`).
public struct ClickerReply: Decodable, Sendable {
    public var ok = false
    public var why: String?
    public var on: Bool?
    public var rect: [Double]?
    public var hz: Int?
    public var phone: Bool?
    public var route: String?
    public var shot: Bool?
    public var note: String?
    public var jpeg: String?

    enum CodingKeys: String, CodingKey {
        case ok, why, on, rect, hz, phone, shot, note, jpeg
        case route = "where"
    }

    /// One line for the shortcut's banner: what happened, or why not.
    public var summary: String {
        if !ok { return why ?? "没成" }
        if on == true { return "开始连点（每秒 \(hz ?? 3) 下）" }
        if let note, !note.isEmpty { return note }
        return "连点停了"
    }
}

public enum ClickerLink {
    /// The Mac (macbook-air) on his tailnet.
    static let host = NWEndpoint.Host("100.110.87.36")
    static let port = NWEndpoint.Port(rawValue: 8941)!

    public static func send(_ request: [String: Any], timeout: TimeInterval = 12) async throws -> ClickerReply {
        let line = try JSONSerialization.data(withJSONObject: request) + Data("\n".utf8)
        let data = try await exchange(line, timeout: timeout)
        return try JSONDecoder().decode(ClickerReply.self, from: data)
    }

    /// Sends `line`, reads up to the newline the Mac ends its answer with.
    private static func exchange(_ line: Data, timeout: TimeInterval) async throws -> Data {
        let conn = NWConnection(host: host, port: port, using: .tcp)
        let box = ReplyBox()
        return try await withCheckedThrowingContinuation { cont in
            box.cont = cont
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: line, completion: .contentProcessed { error in
                        if let error { box.finish(conn, .failure(error)) } else { receive(conn, box) }
                    })
                case .failed(let error), .waiting(let error):
                    box.finish(conn, .failure(error))
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                box.finish(conn, .failure(ClickerError.timeout))
            }
        }
    }

    private static func receive(_ conn: NWConnection, _ box: ReplyBox) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
            if let data { box.add(data) }
            if let error { box.finish(conn, .failure(error)); return }
            if let line = box.line() { box.finish(conn, .success(line)); return }
            if done { box.finish(conn, .failure(ClickerError.closed)); return }
            receive(conn, box)
        }
    }
}

enum ClickerError: LocalizedError {
    case timeout, closed
    var errorDescription: String? {
        switch self {
        case .timeout: "电脑没回话（电脑关着，或手机没连上 Tailscale）"
        case .closed: "电脑断开了"
        }
    }
}

/// The received bytes and the one resume of the continuation, across the connection's callbacks.
private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var resumed = false
    var cont: CheckedContinuation<Data, Error>?

    func add(_ data: Data) { lock.withLock { buffer.append(data) } }

    func line() -> Data? {
        lock.withLock { buffer.firstIndex(of: 0x0A).map { buffer[..<$0] } }
    }

    func finish(_ conn: NWConnection, _ result: Result<Data, Error>) {
        let c: CheckedContinuation<Data, Error>? = lock.withLock {
            if resumed { return nil }
            resumed = true
            return cont
        }
        guard let c else { return }
        conn.cancel()
        c.resume(with: result)
    }
}

/// 手机 › 连点: where on the game's picture to tap and how fast, set here; started and stopped from the game by the
/// AssistiveTouch button running the 「连点开关」 shortcut (Darwin/Sources/ClickerIntents.swift).
struct ClickerPage: View {
    @State private var reply: ClickerReply?
    @State private var picture: UIImage?
    @State private var area = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    @State private var hz = 3
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                LabeledContent("电脑", value: linkText)
                if let r = reply, r.ok || r.on != nil {
                    LabeledContent("连点", value: r.on == true ? "在点" : "没在点")
                }
            } footer: {
                if let note = reply?.note, !note.isEmpty { Text(note) }
            }

            Section {
                if let picture {
                    areaPicker(picture)
                        .listRowInsets(EdgeInsets())
                } else {
                    Text("还没有游戏画面").foregroundStyle(.secondary)
                }
            } header: {
                Text("点哪里")
            } footer: {
                Text(picture == nil
                     ? "在游戏里轻点两下悬浮球，电脑记下这一屏的画面，回到这里就能框。"
                     : "在画面上拖一下，框出要点的那块；连点时在框里随机落点。")
            }

            Section {
                Stepper("每秒 \(hz) 下", value: $hz, in: 1...10)
            } header: {
                Text("速度")
            }

            Section {
                Text("设置 › 辅助功能 › 触控 › 辅助触控：打开，「轻点一下」选「连点开关」，「轻点两下」选「连点：记下这屏画面」。")
            } header: {
                Text("悬浮球")
            } footer: {
                Text("电脑要连得上这台手机才能点：手机连着 Wi-Fi，或者开热点给红米、红米的 Tailscale 开着。")
            }
        }
        .navigationTitle("连点")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: hz) { _, _ in if loaded { Task { await save() } } }
    }

    private var linkText: String {
        if let failure { return failure }
        guard let r = reply else { return "正在问…" }
        if r.phone == true { return "连着手机（\(r.route ?? "")）" }
        return "连不到手机"
    }

    /// The saved picture with the area drawn on it; a drag draws a new area (Photos' crop draws its frame on the
    /// picture the same way).
    private func areaPicker(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let s = geo.size
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.2))
                        .frame(width: area.width * s.width, height: area.height * s.height)
                        .position(x: area.midX * s.width, y: area.midY * s.height)
                        .allowsHitTesting(false)
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4)
                            .onChanged { v in
                                let a = unit(v.startLocation, s), b = unit(v.location, s)
                                area = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                              width: abs(a.x - b.x), height: abs(a.y - b.y))
                            }
                            .onEnded { _ in Task { await save() } })
                }
            }
            .accessibilityLabel("游戏画面，框出的是连点的区域")
    }

    private func unit(_ p: CGPoint, _ s: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, p.x / s.width)), y: min(1, max(0, p.y / s.height)))
    }

    private func load() async {
        do {
            let r = try await ClickerLink.send(["cmd": "state"])
            reply = r
            failure = nil
            if let v = r.rect, v.count == 4 {
                area = CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
            }
            if let h = r.hz { hz = h }
            if r.shot == true, let s = try? await ClickerLink.send(["cmd": "getshot"]), let b64 = s.jpeg,
               let data = Data(base64Encoded: b64) {
                picture = UIImage(data: data)
            }
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    private func save() async {
        let rect = [area.minX, area.minY, area.maxX, area.maxY]
        if let r = try? await ClickerLink.send(["cmd": "set", "rect": rect, "hz": hz]) { reply = r }
    }
}
#endif
