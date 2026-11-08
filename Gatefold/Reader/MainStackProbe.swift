import Darwin
import Foundation

// #94 probe (not for merge): while the main thread is held, a watchdog thread signals it; the signal
// handler, running on the main thread, records its own return addresses. The watchdog counts frames
// across samples and logs the commonest (code symbols only, never the book's words).

nonisolated(unsafe) private var probeFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 96)
nonisolated(unsafe) private var probeCount: Int32 = 0
nonisolated(unsafe) private var probeDone: Int32 = 0
nonisolated(unsafe) private var probeInstalled = false
nonisolated(unsafe) private var probeMain: pthread_t?

enum MainStackProbe {
    /// Call on the main thread once, before any `sample()`.
    static func install() {
        guard pthread_main_np() != 0 else { return }
        probeMain = pthread_self()
        guard !probeInstalled else { return }
        probeInstalled = true
        signal(SIGUSR2) { _ in
            probeCount = backtrace(probeFrames, 96)
            OSMemoryBarrier()
            probeDone = 1
        }
    }

    /// One stack of the main thread, symbolised, outermost last; nil when it didn't answer in 50 ms.
    static func sample() -> [String]? {
        guard probeInstalled, let main = probeMain else { return nil }
        probeDone = 0
        OSMemoryBarrier()
        pthread_kill(main, SIGUSR2)
        var waited = 0
        while probeDone == 0, waited < 50 { usleep(1000); waited += 1 }
        guard probeDone == 1 else { return nil }
        var out: [String] = []
        // Skip the handler's own frames (backtrace, the closure, _sigtramp).
        for i in 0..<Int(probeCount) {
            guard let address = probeFrames[i] else { continue }
            var info = Dl_info()
            if dladdr(address, &info) != 0, let name = info.dli_sname {
                let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
                out.append("\(image)`\(String(cString: name))")
            } else {
                out.append("?")
            }
        }
        if let tramp = out.firstIndex(where: { $0.contains("_sigtramp") }) { out.removeFirst(tramp + 1) }
        return out
    }

    /// The commonest frames over a stall's samples: app frames (Gatefold, Readium) and the leaf.
    static func summary(_ stacks: [[String]]) -> String {
        var app: [String: Int] = [:], leaf: [String: Int] = [:]
        for stack in stacks {
            if let top = stack.first { leaf[top, default: 0] += 1 }
            for frame in Set(stack) where frame.hasPrefix("Gatefold") || frame.contains("Readium") {
                app[frame, default: 0] += 1
            }
        }
        func top(_ d: [String: Int], _ n: Int) -> String {
            d.sorted { $0.value > $1.value }.prefix(n).map { "\($0.value)x \($0.key)" }.joined(separator: " ; ")
        }
        return "\(stacks.count) samples; app: \(top(app, 12)) || leaf: \(top(leaf, 4))"
    }
}
