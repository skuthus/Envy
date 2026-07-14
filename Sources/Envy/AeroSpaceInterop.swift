import AppKit
import Network

/// Best-effort interop with the AeroSpace tiling window manager
/// (github.com/nikitabobko/AeroSpace), if it's running. No-op for
/// everyone else — the socket existence check below is the only cost paid
/// by users who don't have it.
///
/// Talks directly to AeroSpace's own documented Unix-domain-socket
/// protocol (docs/guide.adoc "AeroSpace socket protocol") rather than
/// shelling out to the `aerospace` CLI binary — the binary isn't
/// necessarily anywhere on $PATH at all (confirmed on a real machine:
/// AeroSpace installed as a standalone .app bundle rather than via
/// Homebrew, which is exactly how AeroSpace itself ships), while the
/// socket lives at a fixed, predictable path regardless of how AeroSpace
/// was installed, and only exists while its background server is
/// actually running.
///
/// AeroSpace reimplements its own "workspace" concept instead of using
/// native macOS Spaces, and physically moves windows belonging to a
/// non-focused workspace off-screen into a hidden corner — independent of
/// whether the window is floating or tiled (confirmed in AeroSpace's own
/// source, Sources/AppBundle/layout/refresh.swift, layoutWorkspaces()).
/// Envy's global summon hotkey is registered via Carbon
/// (GlobalHotKey.swift), entirely outside AeroSpace's own event system —
/// AeroSpace has no way to know a summon just happened, so without this,
/// Envy's window can still be sitting off-screen on whatever workspace it
/// was last visible on, even after this app calls makeKeyAndOrderFront.
/// There's no built-in "keep this window on whatever workspace I'm
/// looking at" option in AeroSpace itself yet — see its open issues #272
/// ("scratchpad") and #510 ("Hotkey Window / Guake-style windows").
enum AeroSpaceInterop {
    private static let protocolVersion: UInt32 = 1
    private static let socketPath = "/tmp/bobko.aerospace-\(NSUserName()).sock"

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Moves the window with the given windowNumber onto whichever
    /// AeroSpace workspace is currently focused and asks AeroSpace to
    /// focus it there. Takes a raw window number rather than an NSWindow
    /// so callers can safely dispatch this to a background queue — see the
    /// call sites in EnvyApp.swift for why that matters. Every call here is
    /// a separate blocking socket round trip (up to ~0.3s each in the worst
    /// case), so this must never run on the main thread: doing so used to
    /// delay the window actually appearing by however long all of these
    /// took to complete, sequentially.
    static func bringToFocusedWorkspace(windowNumber: Int) {
        guard isAvailable else { return }
        guard let workspace = send(["list-workspaces", "--focused"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !workspace.isEmpty
        else { return }
        let windowID = String(windowNumber)
        // Force Envy's window into AeroSpace's floating layer before moving
        // it. Confirmed in AeroSpace's own source
        // (MoveNodeToWorkspaceCommand.swift, moveWindowToWorkspace(_:_:_:)):
        // move-node-to-workspace binds a *tiled* window into the target
        // workspace's rootTilingContainer, but a *floating* one into a
        // separate floatingWindowsContainer instead. In accordion layout,
        // inserting a brand-new node into that tiling container is what was
        // reshuffling which window the accordion shows as "expanded,"
        // yanking some unrelated app to the front instead of (or alongside)
        // Envy. `layout floating` is idempotent — a no-op if already
        // floating — so this is safe to send on every single summon rather
        // than only the first.
        send(["layout", "floating", "--window-id", windowID])
        send(["move-node-to-workspace", workspace, "--window-id", windowID])
        send(["focus", "--window-id", windowID])
    }

    /// One round trip over AeroSpace's socket protocol: connect, exchange
    /// the 4-byte version handshake, send a length-prefixed JSON request,
    /// read the length-prefixed JSON response, and return its stdout.
    /// Blocking with a hard timeout — this is local IPC to an
    /// already-running server, so it's normally near-instant; the timeout
    /// only guards against a stale socket file left behind by a server
    /// that's no longer actually listening.
    @discardableResult
    private static func send(_ args: [String]) -> String? {
        guard let requestBody = try? JSONSerialization.data(withJSONObject: [
            "args": args, "stdin": "", "windowId": NSNull(), "workspace": NSNull(),
        ]) else { return nil }

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox(semaphore: semaphore)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: leBytes(protocolVersion), completion: .contentProcessed { error in
                    guard error == nil else { box.finish(nil); return }
                    readExact(connection, 4) { _ in
                        connection.send(content: framed(requestBody), completion: .contentProcessed { error in
                            guard error == nil else { box.finish(nil); return }
                            readExact(connection, 4) { lengthBytes in
                                guard let lengthBytes else { box.finish(nil); return }
                                let length = Int(uleBytes(lengthBytes))
                                readExact(connection, length) { body in
                                    guard let body,
                                          let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                                          let stdout = json["stdout"] as? String
                                    else { box.finish(nil); return }
                                    box.finish(stdout)
                                }
                            }
                        })
                    }
                })
            case .failed, .cancelled:
                box.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        _ = semaphore.wait(timeout: .now() + 0.3)
        connection.cancel()
        return box.value
    }

    /// Bridges NWConnection's @Sendable completion handlers back to a
    /// single blocking result — a plain captured `var`/local `func` isn't
    /// Sendable, so the mutable state and the "only the first callback in
    /// this chain wins" guard live here instead, behind a lock.
    private final class ResultBox: @unchecked Sendable {
        private let semaphore: DispatchSemaphore
        private let lock = NSLock()
        private var _value: String?
        private var finished = false

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }

        init(semaphore: DispatchSemaphore) {
            self.semaphore = semaphore
        }

        func finish(_ value: String?) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            _value = value
            semaphore.signal()
        }
    }

    private static func readExact(_ connection: NWConnection, _ count: Int, completion: @escaping @Sendable (Data?) -> Void) {
        guard count > 0 else {
            completion(Data())
            return
        }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            guard error == nil, let data, data.count == count else {
                completion(nil)
                return
            }
            completion(data)
        }
    }

    // Manual byte composition rather than `Data.withUnsafeBytes { $0.load(as:) }`
    // — Data doesn't guarantee 4-byte alignment, so a raw load can trap;
    // this is endian-explicit and always safe regardless of host endianness.
    private static func leBytes(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private static func uleBytes(_ data: Data) -> UInt32 {
        let bytes = [UInt8](data)
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }

    private static func framed(_ payload: Data) -> Data {
        leBytes(UInt32(payload.count)) + payload
    }
}
