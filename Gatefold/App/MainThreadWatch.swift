#if DEBUG
import Darwin
import Foundation

/// Tests only: logs each time the main thread goes a second or more without running a queued block,
/// and what it was running, so a UI query that times out (gatefold#28) can be laid against what the
/// app was doing. A query waits on the app's main thread.
///
/// A timer on its own queue sends the main queue a ping every 250 ms, one at a time. When a ping comes
/// back a second or more late, the hold is logged with its length; while one is still out it is logged
/// as still held at 1 s and every 5 s after, so a hold the app doesn't outlive (a test relaunching it)
/// still shows. Pings go out on the 250 ms tick, so lengths read up to 250 ms short.
///
/// While a ping is out, main's stack is sampled at 1 s and every 2 s after (up to 6 a hold) and logged
/// as `main: sample` lines, so a hold names its work. A tick of the watch's own timer that comes a second
/// or more late is logged too: then the whole process wasn't run (a loaded machine), not just main.
/// Debug builds only (UI tests run the Debug configuration, `project.yml`), and only in a UI-test launch.
final class MainThreadWatch: @unchecked Sendable {
    // Everything below is touched only on `queue`, after `startIfUITest` hands it over.
    private let queue = DispatchQueue(label: "bot.ouro.gatefold.main-watch", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var outstanding: DispatchTime?
    private var nextStillHeldMark = MainThreadWatch.logAtMs
    private var nextSampleMark = MainThreadWatch.logAtMs
    private var samplesThisHold = 0
    private var samples = 0
    private var lastTick: DispatchTime?
    private var lastGapWasLate = false
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    /// Filled while main is suspended, so nothing there allocates (main may hold malloc's lock).
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: MainThreadWatch.maxFrames)
    /// Main's registers as `thread_get_state` writes them (`arm_thread_state64_t`: x0–x28, fp, lr, sp, pc,
    /// cpsr, pad), read at fixed offsets: nothing in the suspend window asks the runtime for a C struct's
    /// metadata, which a Debug build's first request would register under a lock main may hold.
    private let registers: UnsafeMutableRawPointer = {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MainThreadWatch.stateBytes, alignment: 16)
        raw.bindMemory(to: natural_t.self, capacity: Int(MainThreadWatch.stateCount))
        return raw
    }()

    private static let shared = MainThreadWatch()
    private static let logAtMs = 1_000
    private static let maxFrames = 40
    private static let framesPerLine = 3
    private static let stateBytes = 272
    private static let stateCount = mach_msg_type_number_t(272 / 4)

    /// Starts the watch in a UI-test launch; does nothing otherwise.
    @MainActor
    static func startIfUITest() {
        guard LaunchOptions.isUITest else { return }
        let main = mach_thread_self()
        let thread = pthread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(thread))
        let size = UInt(pthread_get_stacksize_np(thread))
        shared.queue.async {
            shared.mainThread = main
            shared.stackHigh = top
            shared.stackLow = top - size
            shared.start()
        }
    }

    private func start() {
        guard timer == nil else { return }
        #if arch(arm64)
        // The offsets `sampleMain` reads at, checked here, outside any suspend, against the SDK's layout.
        typealias State = arm_thread_state64_t
        if MemoryLayout<State>.size != Self.stateBytes || MemoryLayout<State>.offset(of: \State.__fp) != 232
            || MemoryLayout<State>.offset(of: \State.__lr) != 240 || MemoryLayout<State>.offset(of: \State.__sp) != 248
            || MemoryLayout<State>.offset(of: \State.__pc) != 256 {
            readerLog.error("main: the register layout isn't the one sampled; stack samples are off")
            mainThread = 0
        }
        #endif
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(20))
        timer.setEventHandler { [unowned self] in tick() }
        self.timer = timer
        timer.resume()
        readerLog.notice("main: watch started")
    }

    private func tick() {
        let now = DispatchTime.now()
        lastGapWasLate = false
        if let last = lastTick {
            let gap = Self.ms(from: last, to: now)
            if gap >= Self.logAtMs {
                lastGapWasLate = true
                readerLog.notice("main: watch tick late \(gap, privacy: .public) ms (the process wasn't run)")
            }
        }
        lastTick = now
        let late = lastGapWasLate
        if let sent = outstanding {
            let waited = Self.ms(from: sent, to: now)
            if waited >= nextStillHeldMark {
                readerLog.notice("main: still held after \(waited, privacy: .public) ms")
                nextStillHeldMark = waited + 5_000
            }
            // Not on a late tick: the process itself wasn't being run, and main's stack says nothing then.
            if waited >= nextSampleMark, samplesThisHold < 6, !late {
                samplesThisHold += 1
                samples += 1
                logSample(number: samples, after: waited)
                nextSampleMark = waited + 2_000
            }
            return
        }
        outstanding = now
        nextStillHeldMark = Self.logAtMs
        nextSampleMark = Self.logAtMs
        samplesThisHold = 0
        DispatchQueue.main.async { [self] in
            let answered = DispatchTime.now()
            queue.async { self.answered(sent: now, at: answered) }
        }
    }

    private func answered(sent: DispatchTime, at answered: DispatchTime) {
        outstanding = nil
        let held = Self.ms(from: sent, to: answered)
        if held >= Self.logAtMs { readerLog.notice("main: held \(held, privacy: .public) ms") }
    }

    /// Logs main's stack, innermost frame first, a few frames a line: each `image+0xoffset` (for `atos`
    /// against the build's products), then the nearest exported symbol and its offset when there is one.
    /// The suspend time is an upper bound: it includes the suspend and resume calls themselves.
    private func logSample(number: Int, after waited: Int) {
        let began = DispatchTime.now()
        let (count, resumed) = sampleMain()
        let suspendedUs = (DispatchTime.now().uptimeNanoseconds &- began.uptimeNanoseconds) / 1_000
        readerLog.notice("main: sample \(number, privacy: .public) at \(waited, privacy: .public) ms: \(count, privacy: .public) frames, main suspended at most \(suspendedUs, privacy: .public) us\(resumed ? "" : "; resume failed", privacy: .public)")
        guard count > 0 else { return }
        let described = (0..<count).map { Self.describe(frames[$0], isReturn: $0 > 0) }
        var line = 0
        for start in stride(from: 0, to: described.count, by: Self.framesPerLine) {
            line += 1
            let part = described[start..<min(start + Self.framesPerLine, described.count)].joined(separator: " < ")
            readerLog.notice("main: sample \(number, privacy: .public).\(line, privacy: .public) at \(waited, privacy: .public) ms: \(part, privacy: .public)")
        }
    }

    /// Suspends main, reads its registers and walks its frame pointers into `frames` (at most
    /// `maxFrames`), and resumes it. Between suspend and resume it only reads memory into buffers made
    /// beforehand: no allocation, no lock, no runtime metadata. Frame 1 is `lr`: the caller when main is in
    /// a leaf (a kernel trap, as when it waits), otherwise a stale address inside frame 0's function.
    private func sampleMain() -> (frames: Int, resumed: Bool) {
        #if arch(arm64)
        let flavor = thread_state_flavor_t(ARM_THREAD_STATE64)
        var stateCount = Self.stateCount
        let state = registers.assumingMemoryBound(to: natural_t.self)
        guard mainThread != 0, thread_suspend(mainThread) == KERN_SUCCESS else { return (0, true) }
        var count = 0
        if thread_get_state(mainThread, flavor, state, &stateCount) == KERN_SUCCESS {
            let fp0 = UInt(registers.load(fromByteOffset: 232, as: UInt64.self))
            let lr = UInt(registers.load(fromByteOffset: 240, as: UInt64.self))
            let sp = UInt(registers.load(fromByteOffset: 248, as: UInt64.self))
            frames[0] = UInt(registers.load(fromByteOffset: 256, as: UInt64.self))
            frames[1] = lr
            count = 2
            var fp = fp0
            let low = max(stackLow, sp)
            while count < Self.maxFrames, fp >= low, fp <= stackHigh &- 16, fp % 16 == 0,
                  let pair = UnsafePointer<UInt>(bitPattern: fp) {
                let next = pair[0], back = pair[1]
                guard back != 0 else { break }
                frames[count] = back
                count += 1
                guard next > fp else { break }
                fp = next
            }
        }
        let resumed = thread_resume(mainThread) == KERN_SUCCESS
        return (count, resumed)
        #else
        return (0, true)
        #endif
    }

    private static func describe(_ address: UInt, isReturn: Bool) -> String {
        // A return address points past its call; look up the call itself.
        let lookup = isReturn && address > 0 ? address - 1 : address
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0 else { return "0x" + String(address, radix: 16) }
        let image = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
        // Always the image offset, for `atos` against the build's products; the nearest exported symbol too.
        let offset = "\(image)+0x" + String(lookup &- UInt(bitPattern: info.dli_fbase), radix: 16)
        if let name = info.dli_sname, let symbol = info.dli_saddr {
            return "\(offset) \(String(String(cString: name).prefix(120)))+\(lookup &- UInt(bitPattern: symbol))"
        }
        return offset
    }

    private static func ms(from start: DispatchTime, to end: DispatchTime) -> Int {
        Int((end.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000)
    }
}
#endif
