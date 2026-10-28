import AVFoundation
import Flutter
import Foundation
import UIKit

/// Streaming V2 — the native half of `AVAssetResourceLoader`.
///
/// The Dart side owns TDLib, the download window and "what is readable right
/// now"; this side owns AVFoundation. Three channels keep the split exact:
///
/// * `tgmedia/streaming`        — Dart → native commands;
/// * `tgmedia/streaming/supply` — native → Dart byte requests;
/// * `tgmedia/streaming/events` — native → Dart player status.
///
/// Nothing here opens a socket. There is no HTTP status line to get wrong and
/// no connection lifetime to mismanage: the loader answers byte ranges
/// directly, which is the whole point of moving off the V1 proxy.
enum TGMediaStreamingPlugin {
  /// `FlutterBaseRegistrar` is the common base of `FlutterPluginRegistrar` and
  /// `FlutterApplicationRegistrar`. The app registers this on the application
  /// registrar (it must exist before the first frame), so the narrower
  /// `FlutterPluginRegistrar` type would not accept it — and the only two
  /// facilities used here, `messenger()` and `registerViewFactory`, live on
  /// the base protocol anyway.
  static func register(with registrar: FlutterBaseRegistrar) {
    let host = TGMediaStreamingHost.install(messenger: registrar.messenger())
    host.attach()
    // The view is only the `AVPlayerLayer`; every overlay and gesture stays in
    // Flutter, so the immersive feed looks exactly as before.
    // Swift renames the ObjC selector `registerViewFactory:withId:` to
    // `register(_:withId:)`; the compiler rejects the ObjC spelling.
    registrar.register(
      TGMediaPlayerViewFactory(host: host),
      withId: "tgmedia/player_view"
    )
  }
}

/// One answer to "give me bytes at `offset`", decoded from the Dart map.
struct TGSupply {
  let path: String
  let from: Int64
  let to: Int64
  let total: Int64
  let completed: Bool
  let downloading: Bool
  let waitingMillis: Int64
  let errorCode: String?
  let errorMessage: String?

  var hasData: Bool { from >= 0 && to >= from }

  init(path: String, from: Int64, to: Int64, total: Int64, completed: Bool,
       downloading: Bool, waitingMillis: Int64, errorCode: String?,
       errorMessage: String?) {
    self.path = path
    self.from = from
    self.to = to
    self.total = total
    self.completed = completed
    self.downloading = downloading
    self.waitingMillis = waitingMillis
    self.errorCode = errorCode
    self.errorMessage = errorMessage
  }

  init(map: [String: Any]) {
    path = map["path"] as? String ?? ""
    from = TGMediaNumber.int64(map["from"]) ?? -1
    to = TGMediaNumber.int64(map["to"]) ?? -1
    total = TGMediaNumber.int64(map["total"]) ?? 0
    completed = map["completed"] as? Bool ?? false
    downloading = map["downloading"] as? Bool ?? true
    waitingMillis = TGMediaNumber.int64(map["waitingMillis"]) ?? 0
    errorCode = map["errorCode"] as? String
    errorMessage = map["errorMessage"] as? String
  }

  static func failure(_ code: String, _ message: String) -> TGSupply {
    return TGSupply(
      path: "", from: -1, to: -1, total: 0, completed: false,
      downloading: false, waitingMillis: 0, errorCode: code,
      errorMessage: message
    )
  }
}

enum TGMediaNumber {
  static func int64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let int = value as? Int64 { return int }
    if let int = value as? Int { return Int64(int) }
    return nil
  }
}

/// One play attempt: total length, completeness, content type, and the byte
/// supply that answers AVFoundation.
final class TGMediaSession {
  let id: String
  let fileId: Int64
  let totalBytes: Int64
  let completed: Bool
  let mimeType: String
  private weak var host: TGMediaStreamingHost?

  /// Set by `closeSession` / `disposePlayer`. Once closed, every byte request
  /// is answered with `SESSION_CLOSED` — that is how a request left over from
  /// a video the user swiped past is refused instead of being served from the
  /// new video's file.
  private(set) var isClosed = false

  init(id: String, fileId: Int64, totalBytes: Int64, completed: Bool,
       mimeType: String, host: TGMediaStreamingHost) {
    self.id = id
    self.fileId = fileId
    self.totalBytes = totalBytes
    self.completed = completed
    self.mimeType = mimeType
    self.host = host
  }

  /// UTI-style content type. AVFoundation wants a UTI here, not a MIME string:
  /// handing it `video/mp4` makes it treat the asset as an unknown type and
  /// refuse to build tracks even when every byte was served correctly.
  var contentType: String {
    let lower = mimeType.lowercased()
    if lower.contains("quicktime") || lower.hasSuffix("/mov") {
      return AVFileType.mov.rawValue
    }
    if lower.contains("m4v") { return AVFileType.m4v.rawValue }
    if lower.contains("mp4") { return AVFileType.mp4.rawValue }
    if lower.contains("webm") { return "org.webmproject.webm" }
    return AVFileType.mp4.rawValue
  }

  func close() {
    isClosed = true
  }

  /// Blocking byte request. Called from a resource-loader queue, never from the
  /// platform thread: the Dart answer arrives through the channel callback.
  func supply(offset: Int64, length: Int64, requestId: Int64) -> TGSupply {
    guard !isClosed, let host = host else {
      return TGSupply.failure("SESSION_CLOSED", "播放已切换")
    }
    let semaphore = DispatchSemaphore(value: 0)
    var reading = TGSupply.failure("SUPPLY_TIMEOUT", "Dart 未在 15 秒内回应")
    host.supply(sessionId: id, offset: offset, length: length,
                requestId: requestId) { result in
      reading = result
      semaphore.signal()
    }
    // A safety net for a wedged engine, not a playback timeout: the Dart
    // handler answers from in-memory state and returns in microseconds.
    if semaphore.wait(timeout: .now() + 15) == .timedOut {
      return TGSupply.failure("SUPPLY_TIMEOUT", "Dart 未在 15 秒内回应")
    }
    return reading
  }
}

final class TGMediaStreamingHost: NSObject, FlutterStreamHandler {
  private(set) static var shared: TGMediaStreamingHost?

  static func install(messenger: FlutterBinaryMessenger) -> TGMediaStreamingHost {
    let host = TGMediaStreamingHost(messenger: messenger)
    shared = host
    return host
  }

  private let controlChannel: FlutterMethodChannel
  private let supplyChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel

  private var sink: FlutterEventSink?
  private var sessions: [String: TGMediaSession] = [:]
  private var players: [String: TGMediaPlayer] = [:]

  init(messenger: FlutterBinaryMessenger) {
    controlChannel = FlutterMethodChannel(
      name: "tgmedia/streaming", binaryMessenger: messenger)
    supplyChannel = FlutterMethodChannel(
      name: "tgmedia/streaming/supply", binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(
      name: "tgmedia/streaming/events", binaryMessenger: messenger)
    super.init()
  }

  func attach() {
    controlChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    eventChannel.setStreamHandler(self)
  }

  // MARK: - control

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any]) ?? [:]
    switch call.method {
    case "openSession":
      openSession(args, result: result)
    case "closeSession":
      guard let id = args["sessionId"] as? String else {
        result(TGMediaStreamingHost.badArgs("sessionId"))
        return
      }
      closeSession(id)
      result(nil)
    case "createPlayer":
      guard let id = args["sessionId"] as? String, let session = sessions[id] else {
        result(TGMediaStreamingHost.missingSession(args["sessionId"]))
        return
      }
      let player = TGMediaPlayer(session: session, host: self)
      players[id] = player
      player.prepare()
      result(nil)
    case "play":
      players[args["sessionId"] as? String ?? ""]?.play()
      result(nil)
    case "pause":
      players[args["sessionId"] as? String ?? ""]?.pause()
      result(nil)
    case "seek":
      let id = args["sessionId"] as? String ?? ""
      let position = TGMediaNumber.int64(args["positionMs"]) ?? 0
      players[id]?.seek(toMilliseconds: position)
      result(nil)
    case "setVolume":
      let id = args["sessionId"] as? String ?? ""
      let volume = (args["volume"] as? NSNumber)?.doubleValue ?? 1.0
      players[id]?.setVolume(Float(volume))
      result(nil)
    case "disposePlayer":
      let id = args["sessionId"] as? String ?? ""
      players.removeValue(forKey: id)?.stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func openSession(_ args: [String: Any], result: @escaping FlutterResult) {
    guard let id = args["sessionId"] as? String else {
      result(TGMediaStreamingHost.badArgs("sessionId"))
      return
    }
    let session = TGMediaSession(
      id: id,
      fileId: TGMediaNumber.int64(args["fileId"]) ?? 0,
      totalBytes: TGMediaNumber.int64(args["totalBytes"]) ?? 0,
      completed: args["completed"] as? Bool ?? false,
      mimeType: args["mimeType"] as? String ?? "video/mp4",
      host: self
    )
    sessions[id] = session
    emit(type: "sessionOpen", session: session, extra: [
      "total": session.totalBytes,
      "completed": session.completed,
    ])
    // The facts AVFoundation needs before it can make a single request. Dart
    // gets the same values back, so both sides record one truth.
    result([
      "totalBytes": session.totalBytes,
      "contentType": session.contentType,
      "byteRangeAccessSupported": true,
      // A growing file is not "available on demand": claiming it is makes
      // AVPlayer read past the downloaded prefix and fail with -1005.
      "entireLengthAvailableOnDemand": session.completed,
    ])
  }

  private func closeSession(_ id: String) {
    if let session = sessions.removeValue(forKey: id) {
      session.close()
    }
    players.removeValue(forKey: id)?.stop()
  }

  static func badArgs(_ name: String) -> FlutterError {
    return FlutterError(code: "bad_args", message: "\(name) is required", details: nil)
  }

  static func missingSession(_ value: Any?) -> FlutterError {
    let id = value as? String ?? "-"
    return FlutterError(code: "no_session", message: "unknown session \(id)", details: nil)
  }

  // MARK: - supply (native -> Dart)

  func supply(sessionId: String, offset: Int64, length: Int64, requestId: Int64,
              completion: @escaping (TGSupply) -> Void) {
    let args: [String: Any] = [
      "sessionId": sessionId,
      "offset": offset,
      "length": length,
      "requestId": requestId,
    ]
    let invoke = { [weak self] in
      guard let self = self else {
        completion(TGSupply.failure("SUPPLY_UNAVAILABLE", "host released"))
        return
      }
      self.supplyChannel.invokeMethod("supply", arguments: args) { reply in
        if let map = reply as? [String: Any] {
          completion(TGSupply(map: map))
        } else {
          completion(TGSupply.failure("SUPPLY_UNAVAILABLE", "no reply from Dart"))
        }
      }
    }
    // Channel calls must go out on the platform thread; the caller is a
    // resource-loader queue thread.
    if Thread.isMainThread {
      invoke()
    } else {
      DispatchQueue.main.async(execute: invoke)
    }
  }

  // MARK: - events (native -> Dart)

  func emit(type: String, session: TGMediaSession?, extra: [String: Any]) {
    var payload = extra
    payload["type"] = type
    if let session = session {
      payload["playerId"] = session.id
      payload["sessionId"] = session.id
      payload["fileId"] = session.fileId
    }
    emit(payload)
  }

  func emit(_ payload: [String: Any]) {
    guard let sink = sink else { return }
    if Thread.isMainThread {
      sink(payload)
    } else {
      DispatchQueue.main.async { sink(payload) }
    }
  }

  func onListen(withArguments arguments: Any?,
                eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func player(id: String) -> TGMediaPlayer? {
    return players[id]
  }
}
