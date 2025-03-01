import Cocoa
import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

@MainActor final class Controller: NSObject {
  private weak var restartTimer: Timer?
  private var currentEventTap: CFMachPort?
  private var currentRunLoopSource: CFRunLoopSource?

  private static let fastRestart = false
  private static let wakeRestartTimeout: TimeInterval = fastRestart ? 2 : 10

  private static let immediateRestart = false

  func start() {
    NSLog("Starting all listeners...")

    TouchHandler.shared.registerTouchCallback()

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(receiveWakeNote(_:)),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    setupMultitouchListener()
    setupDisplayReconfigurationCallback()
    registerMouseCallback()
  }

  /// Schedule listeners to be restarted. If a restart is pending, delay it.
  func scheduleRestart(_ delay: TimeInterval) {
    restartTimer?.invalidate()
    restartTimer = Timer.scheduledTimer(
      withTimeInterval: Controller.immediateRestart ? 0 : delay, repeats: false
    ) { [weak self] _ in
      guard let self = self else { return }
      DispatchQueue.main.async {
        self.restartListeners()
      }
    }
  }

  /// Callback for system wake up.
  /// Can be tested by entering `pmset sleepnow` in the Terminal
  @objc private func receiveWakeNote(_ note: Notification) {
    NSLog("System woke up, restarting in \(Self.wakeRestartTimeout)...")
    scheduleRestart(Self.wakeRestartTimeout)
  }

  private func restartListeners() {
    NSLog("Restarting app functionality...")
    stopUnstableListeners()
    startUnstableListeners()
  }

  private func startUnstableListeners() {
    NSLog("Starting unstable listeners...")
    TouchHandler.shared.registerTouchCallback()
    registerMouseCallback()
  }

  private func stopUnstableListeners() {
    NSLog("Stopping unstable listeners...")
    TouchHandler.shared.unregisterTouchCallback()
    unregisterMouseCallback()
  }

  private func registerMouseCallback() {
    let eventMask = CGEventMask.from(.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp)
    currentEventTap = CGEvent.tapCreate(
      tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
      eventsOfInterest: eventMask, callback: Self.mouseCallback, userInfo: nil)

    if let tap = currentEventTap {
      currentRunLoopSource = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault, tap, 0)
      CFRunLoopAddSource(
        CFRunLoopGetCurrent(), currentRunLoopSource, .commonModes)
      CGEvent.tapEnable(tap: tap, enable: true)
    } else {
      NSLog("Couldn't create event tap! Check accessibility permissions.")
      UserDefaults.standard.set(true, forKey: "NSStatusItem Visible Item-0")
      scheduleRestart(5)
    }
  }

  private func unregisterMouseCallback() {
    // Disable the event tap first
    if let eventTap = currentEventTap {
      CGEvent.tapEnable(tap: eventTap, enable: false)
    }

    // Remove and release the run loop source
    if let runLoopSource = currentRunLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
      currentRunLoopSource = nil
    }

    // Release the event tap
    currentEventTap = nil
  }

  private func setupMultitouchListener() {
    guard let port = IONotificationPortCreate(kIOMasterPortDefault) else {
      NSLog("Failed to create IONotificationPort.")
      return
    }

    if let runLoopSource = IONotificationPortGetRunLoopSource(port)?
      .takeUnretainedValue()
    {
      CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    } else {
      NSLog("Failed to get run loop source from IONotificationPort.")
      IONotificationPortDestroy(port)
      return
    }

    var handle: io_iterator_t = 0
    let err = IOServiceAddMatchingNotification(
      port,
      kIOFirstMatchNotification,
      IOServiceMatching("AppleMultitouchDevice"),
      Self.multitouchDeviceAddedCallback,
      Unmanaged.passUnretained(self).toOpaque(),
      &handle
    )

    if err != KERN_SUCCESS {
      NSLog(
        "Failed to register notification for touchpad attach: %x, will not handle newly attached devices",
        err)
      IONotificationPortDestroy(port)
      return  // this `return` was not previously here. But it's only logical to have it.
    }

    while case let ioService = IOIteratorNext(handle), ioService != 0 {
      do { IOObjectRelease(ioService) }
    }
  }

  private func setupDisplayReconfigurationCallback() {
    CGDisplayRegisterReconfigurationCallback(
      Self.displayReconfigurationCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  // MARK: - Callbacks

  private static let mouseCallback: CGEventTapCallBack = {
    proxy, type, event, refcon in
    if AppUtils.isIgnoredAppBundle() { return Unmanaged.passUnretained(event) }

    let state = GlobalState.shared

    if state.threeDown && (type == .leftMouseDown || type == .rightMouseDown) {
      state.wasThreeDown = true
      event.type = .otherMouseDown
      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
      state.threeDown = false
      state.naturalMiddleClickLastTime = Date()
    }

    if state.wasThreeDown && (type == .leftMouseUp || type == .rightMouseUp) {
      state.wasThreeDown = false
      event.type = .otherMouseUp
      event.setIntegerValueField(.mouseEventButtonNumber, value: kCGMouseButtonCenter)
    }

    return Unmanaged.passUnretained(event)
  }

  /// TODO? is this restart necessary? I don't see any changes when it's removed, but keep in mind I've only spent 5 minutes testing different app and system states
  private static let displayReconfigurationCallback:
  CGDisplayReconfigurationCallBack = { display, flags, userData in
    if flags.contains(.setModeFlag) || flags.contains(.addFlag)
        || flags.contains(.removeFlag) || flags.contains(.disabledFlag)
    {
      print("Display reconfigured, restarting...")
      let controller = Unmanaged<Controller>.fromOpaque(userData!)
        .takeUnretainedValue()
      controller.scheduleRestart(2)
    }
  }

  private static let multitouchDeviceAddedCallback: IOServiceMatchingCallback = {
    (userData, iterator) in
    while case let ioService = IOIteratorNext(iterator), ioService != 0 {
      do { IOObjectRelease(ioService) }
    }

    let controller = Unmanaged<Controller>.fromOpaque(userData!)
      .takeUnretainedValue()
    NSLog("Multitouch device added, restarting...")
    controller.scheduleRestart(2)
  }
}

extension CGEventMask {
  static func from(_ types: CGEventType...) -> Self {
    var mask = 0

    for type in types {
      mask |= (1 << type.rawValue)
    }

    return Self(mask)
  }
}
