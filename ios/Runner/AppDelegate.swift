import AVFoundation
import Flutter
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
  }

  /// UIKit consults the app delegate before any view controller. Flutter's
  /// `FlutterAppDelegate` does not declare this optional `UIApplicationDelegate`
  /// method, so this implementation owns the decision outright — which is what
  /// makes "force landscape" work on a phone that is physically upright.
  func application(
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
