@preconcurrency import ApplicationServices

enum SystemPermissions {
  /// #### To quickly reset the permission, run:
  ///
  /// ```
  /// tccutil reset Accessibility art.ginzburg.MiddleClick
  /// ```
  static func detectAccessibilityIsGranted(forcePrompt: Bool) -> Bool {
    return AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): forcePrompt] as CFDictionary)
  }
}
