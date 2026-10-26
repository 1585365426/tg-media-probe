import AVFoundation
import Flutter
import LocalAuthentication
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Application-level channels are registered on the implicit engine so they
    // exist before the first Flutter frame. `applicationRegistrar` is the
    // supported way to get a binary messenger under the UIScene lifecycle.
    let messenger = engineBridge.applicationRegistrar.messenger()
    OrientationChannel.register(messenger: messenger)
    VideoMetaChannel.register(messenger: messenger)
    BiometricChannel.register(messenger: messenger)
  }

  /// UIKit consults the app delegate before any view controller. Flutter's
  /// `FlutterAppDelegate` already declares this optional `UIApplicationDelegate`
  /// method (hence `override`), and returning our own mask here is what makes
  /// "force landscape" work on a phone that is physically upright.
  override func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    return OrientationChannel.currentMask
  }
}

// MARK: - Orientation control

/// Three modes, matching `ScreenOrientationMode` on the Dart side.
///
/// `followSystem` keeps every orientation the Info.plist allows. `lockedPortrait`
/// and `forcedLandscape` both narrow the mask **and** rotate the current window,
/// because a narrowed mask alone only affects future device rotations.
enum OrientationChannel {
  static let channelName = "tgmedia/orientation"

  /// `.allButUpsideDown` is the default: the app never wants upside-down
  /// portrait, and iOS 15 has no use for it.
  static var currentMask: UIInterfaceOrientationMask = .allButUpsideDown

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "setMode":
        guard let arguments = call.arguments as? [String: Any],
              let mode = arguments["mode"] as? String
        else {
          result(FlutterError(code: "bad_args", message: "mode is required", details: nil))
          return
        }
        apply(mode: mode, result: result)
      case "reset":
        apply(mode: "system", result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func apply(mode: String, result: @escaping FlutterResult) {
    let mask: UIInterfaceOrientationMask
    switch mode {
    case "portrait":
      mask = .portrait
    case "landscape":
      mask = .landscape
    case "system":
      mask = .allButUpsideDown
    default:
      result(FlutterError(code: "bad_mode", message: "unsupported mode: \(mode)", details: nil))
      return
    }
    currentMask = mask
    forceRotation(to: mask)
    result(nil)
  }

  private static func forceRotation(to mask: UIInterfaceOrientationMask) {
    if #available(iOS 16.0, *) {
      guard let scene = keyWindowScene() else { return }
      scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in
        // A rejected update means the device orientation lock is on; the mask
        // still applies to the next physical rotation, which is the correct
        // fallback behaviour rather than a fake success.
      }
      scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
      return
    }

    // iOS 15 has no geometry-update API. Setting the device orientation is the
    // only way to rotate a page immediately; the mask above keeps it there.
    let target: UIInterfaceOrientation
    if mask == .portrait {
      target = .portrait
    } else if let scene = keyWindowScene(), scene.interfaceOrientation.isLandscape {
      target = scene.interfaceOrientation
    } else {
      target = .landscapeRight
    }
    UIDevice.current.setValue(target.rawValue, forKey: "orientation")
    UIViewController.attemptRotationToDeviceOrientation()
  }

  private static func keyWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
  }
}

// MARK: - Video rotation

/// TDLib's `video` object carries no rotation, so the display orientation can
/// only come from the media file. AVFoundation's `preferredTransform` is the
/// authoritative source; anything that is not a clean 0/90/180/270 returns nil
/// and the Dart side records the item as "rotation unknown" instead of guessing.
enum VideoMetaChannel {
  static let channelName = "tgmedia/video_meta"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "rotationDegrees" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
            let path = arguments["path"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      rotationDegrees(path: path, result: result)
    }
  }

  private static func rotationDegrees(path: String, result: @escaping FlutterResult) {
    guard FileManager.default.fileExists(atPath: path) else {
      result(nil)
      return
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
      var error: NSError?
      let status = asset.statusOfValue(forKey: "tracks", error: &error)
      guard status == .loaded else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      guard let track = asset.tracks(withMediaType: .video).first else {
        DispatchQueue.main.async { result(nil) }
        return
      }
      let transform = track.preferredTransform
      let radians = atan2(Double(transform.b), Double(transform.a))
      let degrees = Int((radians * 180.0 / Double.pi).rounded())
      let normalized = ((degrees % 360) + 360) % 360
      let answer: Int? = [0, 90, 180, 270].contains(normalized) ? normalized : nil
      DispatchQueue.main.async {
        if let answer = answer {
          result(answer)
        } else {
          result(nil)
        }
      }
    }
  }
}

// MARK: - Biometric gate (Face ID / Touch ID)

/// Bridges `LocalAuthentication` to `lib/security/biometric.dart`.
///
/// Boundaries this file keeps:
///
/// * The template never leaves the Secure Enclave. `evaluatePolicy` hands back a
///   boolean and an error; there is no API here that could return an image even
///   if something asked for one.
/// * Only `.deviceOwnerAuthenticationWithBiometrics` is used. It cannot fall
///   back to the device passcode on its own, so a stolen phone whose passcode
///   the attacker knows still does not unlock the app — the app passcode is the
///   fallback, and that is a separate verifier.
/// * Outcome names are strings, not `LAError` numbers. A numeric code that shifts
///   between iOS releases would turn "recognition failed" into "sensor missing"
///   and quietly disable the feature.
enum BiometricChannel {
  static let channelName = "com.tgmedia/biometric"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "probe":
        result(probe())
      case "authenticate":
        let reason = (call.arguments as? [String: Any])?["reason"] as? String
        authenticate(reason: reason ?? "解锁 TG Media", result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// Sensor name. Never assume Face ID: an iPhone SE has Touch ID and an
  /// iPhone 8 has no Face ID at all.
  private static func kindName(_ context: LAContext) -> String {
    if #available(iOS 17.0, *), context.biometryType == .opticID {
      return "optic"
    }
    switch context.biometryType {
    case .faceID:
      return "face"
    case .touchID:
      return "touch"
    case .none:
      return "none"
    @unknown default:
      return "unknown"
    }
  }

  /// One snapshot for the settings row: what the device has, whether it can be
  /// used right now, and whether it is temporarily locked out.
  private static func probe() -> [String: Any] {
    let context = LAContext()
    var error: NSError?
    let canEvaluate = context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      error: &error
    )
    let kind = kindName(context)

    // A sensor that exists but cannot be evaluated is still "available" — the
    // distinction matters because the settings toggle should say "先录入面容"
    // rather than "此设备不支持".
    var available = kind != "none"
    var enrolled = canEvaluate
    var lockedOut = false

    if let laError = error as? LAError {
      switch laError.code {
      case .biometryNotEnrolled:
        enrolled = false
      case .biometryLockout:
        // Still enrolled; only a device-passcode unlock clears this.
        enrolled = true
        lockedOut = true
      case .biometryNotAvailable:
        available = false
        enrolled = false
      case .passcodeNotSet:
        // iOS refuses biometrics without a device passcode. The hardware is
        // there, so this is reported as "not enrolled" to the caller.
        enrolled = false
      default:
        break
      }
    }

    return [
      "kind": kind,
      "available": available,
      "enrolled": enrolled,
      "lockedOut": lockedOut,
    ]
  }

  private static func authenticate(reason: String, result: @escaping FlutterResult) {
    let context = LAContext()
    context.localizedCancelTitle = "取消"
    // Shown as the fallback button inside the system sheet. It leads to the app
    // passcode screen, not to the device passcode.
    context.localizedFallbackTitle = "使用应用密码"

    var error: NSError?
    guard context.canEvaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      error: &error
    ) else {
      // No prompt is shown in this branch, so the caller must fall back. The
      // same error mapping is used as for a failed evaluation.
      result(outcomeName(error))
      return
    }

    context.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics,
      localizedReason: reason
    ) { success, evaluationError in
      // The reply must arrive on the main thread: the Dart side resumes a
      // Future that rebuilds the unlock screen.
      DispatchQueue.main.async {
        result(success ? "success" : outcomeName(evaluationError))
      }
    }
  }

  /// Maps `LAError.Code` to the names `BiometricOutcome` parses.
  private static func outcomeName(_ error: Error?) -> String {
    guard let laError = error as? LAError else {
      // A cancelled or interrupted prompt can arrive as a generic error; the
      // safe default is `error`, which makes the caller demand the passcode.
      return "error"
    }
    switch laError.code {
    case .userCancel:
      return "userCancel"
    case .systemCancel:
      return "systemCancel"
    case .userFallback:
      return "userFallback"
    case .biometryLockout:
      return "lockout"
    case .biometryNotEnrolled:
      return "notEnrolled"
    case .biometryNotAvailable:
      return "notAvailable"
    case .passcodeNotSet:
      return "passcodeNotSet"
    case .appCancel:
      return "appCancel"
    case .authenticationFailed:
      // One failed face scan. Reported as `error` on purpose: the UI must not
      // tell the user "wrong password" before they have typed anything.
      return "error"
    case .invalidContext, .notInteractive:
      return "error"
    @unknown default:
      return "error"
    }
  }
}
