import ObjectiveC
import XCTest

/// The UI-test bundle's principal class (`NSPrincipalClass`, project.yml): made once when the bundle loads,
/// before any test, so every launch of the app, in every test class, goes out with os_log's stderr mirror off.
@objc(GatefoldUITestsPrincipal)
final class GatefoldUITestsPrincipal: NSObject {
    override init() {
        super.init()
        LogMirrorOff.install()
    }
}

/// Launches the app with `OS_ACTIVITY_DT_MODE` off (gatefold#28). XCTest launches it in Xcode's debug mode, where
/// each `os_log` call is also written to the app's stderr; when the runner is starved, nothing drains that pipe and
/// the write blocks the app's main thread: 8 of 23 main-thread samples taken during page counts were in that
/// `writev`, from WebKit and from XCTest's own snapshot code (#239's run 43047965291). A shipped app never runs in
/// that mode. Only the mirror goes: `print`, `fatalError` and the runtime's own messages still reach stderr, and
/// the reader log is collected with `log stream`, not from stderr.
enum LogMirrorOff {
    static let variable = "OS_ACTIVITY_DT_MODE"

    static func install() { _ = swapped }

    private static let swapped: Void = {
        let type: AnyClass = XCUIApplication.self
        guard let original = class_getInstanceMethod(type, #selector(XCUIApplication.launch)),
              let replacement = class_getInstanceMethod(type, #selector(XCUIApplication.gatefoldLaunchWithoutLogMirror))
        else { return }
        method_exchangeImplementations(original, replacement)
        print("LogMirrorOff: XCUIApplication.launch asks for \(variable) off (gatefold#28)")
    }()
}

extension XCUIApplication {
    /// Swapped with `launch` (`LogMirrorOff`): asks for the variable off, then runs XCTest's own launch. The app then
    /// sees the variable as absent, not "NO" (#28's probe run 43060812281), which keeps the mirror off just the same.
    /// `dynamic` keeps the call below going through the swap, so it reaches XCTest's launch at any optimization.
    @objc fileprivate dynamic func gatefoldLaunchWithoutLogMirror() {
        launchEnvironment[LogMirrorOff.variable] = "NO"
        gatefoldLaunchWithoutLogMirror()
    }
}
