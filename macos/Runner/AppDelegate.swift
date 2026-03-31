import Cocoa
import FlutterMacOS
import app_links

@main
class AppDelegate: FlutterAppDelegate {
  private var windowChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)

    if let flutterViewController = mainFlutterWindow?.contentViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "landman/window",
        binaryMessenger: flutterViewController.engine.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "activateApp":
          self?.activateAndFocusApp()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      windowChannel = channel
    }

    NSAppleEventManager.shared().setEventHandler(
      self,
      andSelector: #selector(handleAuthCallbackEvent(_:with:)),
      forEventClass: AEEventClass(kInternetEventClass),
      andEventID: AEEventID(kAEGetURL)
    )
  }

  @objc
  private func handleAuthCallbackEvent(
    _ event: NSAppleEventDescriptor,
    with replyEvent: NSAppleEventDescriptor
  ) {
    guard
      let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue
    else {
      return
    }

    activateAndFocusApp()
    AppLinks.shared.handleLink(link: urlString)
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    super.application(application, open: urls)
    activateAndFocusApp()
  }

  private func activateAndFocusApp() {
    let runningApp = NSRunningApplication.current
    let retryDelays: [TimeInterval] = [0.0, 0.2, 0.5, 0.9, 1.4, 2.1, 3.0]

    for delay in retryDelays {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.activateViaAppleScript()
        runningApp.unhide()
        runningApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        self?.mainFlutterWindow?.makeKeyAndOrderFront(nil)
        self?.mainFlutterWindow?.orderFrontRegardless()
      }
    }
  }

  private func activateViaAppleScript() {
    guard let bundleId = Bundle.main.bundleIdentifier else {
      return
    }
    let source = "tell application id \"\(bundleId)\" to activate"
    var error: NSDictionary?
    let script = NSAppleScript(source: source)
    script?.executeAndReturnError(&error)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
