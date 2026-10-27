import AVFoundation
import Flutter
import UIKit

/// `AVPlayer` on top of `AVAssetResourceLoader`.
///
/// Same lifecycle surface as the `video_player` handle on the Dart side
/// (`play` / `pause` / `seek` / `dispose`), but the asset is an
/// `AVURLAsset` with a `tgmedia://` URL whose loader answers byte ranges from
/// the growing TDLib file. No socket is involved at any point.
final class TGMediaPlayer: NSObject {
  let sessionId: String
  private let session: TGMediaSession
  private weak var host: TGMediaStreamingHost?

  private let player = AVPlayer()
  private let loader: TGMediaResourceLoader
  private let layer: AVPlayerLayer

  private var item: AVPlayerItem?
  private var statusObservation: NSKeyValueObservation?
  private var bufferObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?
  private var failedObserver: NSObjectProtocol?

  private var firstFrameEmitted = false
  private var readyEmitted = false
  private var stopped = false

  init(session: TGMediaSession, host: TGMediaStreamingHost) {
    self.sessionId = session.id
    self.session = session
    self.host = host
    self.loader = TGMediaResourceLoader(session: session, host: host)
    self.layer = AVPlayerLayer(player: player)
    super.init()
    layer.videoGravity = .resizeAspect
  }

  /// The layer the platform view hosts. One player, one layer: two views can
  /// never show two videos for the same id.
  var playerLayer: AVPlayerLayer { layer }

  func prepare() {
    guard let url = URL(string: "tgmedia://video/\(sessionId)") else {
      emit("failed", ["message": "invalid tgmedia url"])
      return
    }
    let asset = AVURLAsset(url: url)
    // Must be set before the item is created: AVFoundation asks the loader for
    // content information as soon as the item is built.
    asset.resourceLoader.setDelegate(
      loader, queue: DispatchQueue(label: "tgmedia.assetloader.\(sessionId)"))
    let item = AVPlayerItem(asset: asset)
    self.item = item
    player.replaceCurrentItem(with: item)
    if #available(iOS 10.0, *) {
      player.automaticallyWaitsToMinimizeStalling = true
    }
    observe(item)
    emit("playerCreated", [:])
  }

  private func observe(_ item: AVPlayerItem) {
    statusObservation = item.observe(\.status, options: [.new, .initial]) {
      [weak self] observed, _ in
      guard let self = self else { return }
      switch observed.status {
      case .readyToPlay:
        self.handleReady(observed)
      case .failed:
        self.handleFailure(observed.error)
      default:
        break
      }
    }

    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
      [weak self] observed, _ in
      guard let self = self else { return }
      switch observed.timeControlStatus {
      case .playing:
        self.emit("playing", [:])
        self.markFirstFrameIfNeeded()
      case .waitingToPlayAtSpecifiedRate:
        self.emit("buffering", ["buffering": true])
      default:
        self.emit("buffering", ["buffering": false])
      }
    }

    bufferObservation = item.observe(\.isPlaybackBufferEmpty, options: [.new]) {
      [weak self] observed, _ in
      guard let self = self else { return }
      self.emit("buffering", ["buffering": observed.isPlaybackBufferEmpty])
    }

    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 250, timescale: 1000),
      queue: .main
    ) { [weak self] time in
      guard let self = self else { return }
      let positionMs = Int64((CMTimeGetSeconds(time) * 1000).rounded())
      let durationMs = self.durationMilliseconds()
      self.emit("tick", [
        "positionMs": positionMs,
        "durationMs": durationMs,
        "isPlaying": self.player.rate > 0,
      ])
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      self?.emit("ended", [:])
    }

    failedObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] note in
      let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      self?.handleFailure(error)
    }
  }

  private func handleReady(_ item: AVPlayerItem) {
    guard !readyEmitted else { return }
    readyEmitted = true
    // Portrait-ish content fills the screen, anything wider keeps its whole
    // frame with letterboxing — the same rule the Flutter side applies to the
    // `video_player` surface, so V2 does not change how a video is framed.
    let size = item.presentationSize
    if size.width > 0 && size.height > 0 {
      let ratio = size.width / size.height
      layer.videoGravity = ratio < 0.95 ? .resizeAspectFill : .resizeAspect
    }
    emit("ready", ["durationMs": durationMilliseconds()])
  }

  private func handleFailure(_ error: Error?) {
    guard !stopped else { return }
    let message: String
    if let error = error as NSError? {
      message = "\(error.domain)(\(error.code)): \(error.localizedDescription)"
    } else if let error = error {
      message = "\(error)"
    } else {
      message = "AVPlayer failed without an error"
    }
    emit("failed", ["message": message])
  }

  private func markFirstFrameIfNeeded() {
    guard !firstFrameEmitted, player.rate > 0 else { return }
    firstFrameEmitted = true
    emit("firstFrame", [
      "positionMs": Int64((CMTimeGetSeconds(player.currentTime()) * 1000).rounded()),
    ])
  }

  private func durationMilliseconds() -> Int64 {
    guard let item = item else { return 0 }
    let seconds = CMTimeGetSeconds(item.duration)
    if seconds.isNaN || seconds.isInfinite || seconds < 0 { return 0 }
    return Int64((seconds * 1000).rounded())
  }

  func play() {
    player.play()
  }

  func pause() {
    player.pause()
  }

  func seek(toMilliseconds position: Int64) {
    let target = CMTime(value: position, timescale: 1000)
    // Zero tolerance: a "close enough" seek would read a different byte range
    // than the one the user asked for, and the loader would answer honestly for
    // the wrong offset.
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func setVolume(_ volume: Float) {
    player.isMuted = false
    player.volume = max(0, min(1, volume))
  }

  /// Tears the item down and closes the session, so nothing keeps answering
  /// byte requests for a video nobody is watching.
  func stop() {
    guard !stopped else { return }
    stopped = true
    player.pause()
    if let timeObserver = timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    statusObservation?.invalidate()
    statusObservation = nil
    bufferObservation?.invalidate()
    bufferObservation = nil
    timeControlObservation?.invalidate()
    timeControlObservation = nil
    if let endObserver = endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    if let failedObserver = failedObserver {
      NotificationCenter.default.removeObserver(failedObserver)
      self.failedObserver = nil
    }
    player.replaceCurrentItem(with: nil)
    item = nil
    session.close()
  }

  private func emit(_ type: String, _ extra: [String: Any]) {
    var payload = extra
    payload["playerId"] = sessionId
    payload["type"] = type
    host?.emit(payload)
  }
}

/// Hosts the `AVPlayerLayer` inside a Flutter platform view.
///
/// The layer is attached lazily: Flutter may build the view before the player
/// exists (or after it, depending on frame order), so binding happens on the
/// first layout pass and again whenever the layer is still missing.
final class TGMediaPlayerView: NSObject, FlutterPlatformView {
  private let container: TGMediaLayerHostView
  private let playerId: String
  private weak var host: TGMediaStreamingHost?
  private var attachedLayer: AVPlayerLayer?
  private var attachedPlayer: TGMediaPlayer?

  init(frame: CGRect, playerId: String, host: TGMediaStreamingHost) {
    container = TGMediaLayerHostView(frame: frame)
    self.playerId = playerId
    self.host = host
    super.init()
    container.backgroundColor = .black
    container.onLayout = { [weak self] in self?.attachIfNeeded() }
  }

  func view() -> UIView {
    attachIfNeeded()
    return container
  }

  private func attachIfNeeded() {
    guard let player = host?.player(id: playerId) else { return }
    if attachedPlayer === player, let attached = attachedLayer {
      // `CALayer.autoresizingMask` does not exist on iOS, so the frame is
      // re-applied on every layout pass instead of being automated.
      attached.frame = container.bounds
      return
    }
    attachedLayer?.removeFromSuperlayer()
    let layer = player.playerLayer
    layer.frame = container.bounds
    container.layer.addSublayer(layer)
    attachedLayer = layer
    attachedPlayer = player
  }
}

final class TGMediaLayerHostView: UIView {
  var onLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    onLayout?()
  }
}

final class TGMediaPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private weak var host: TGMediaStreamingHost?

  init(host: TGMediaStreamingHost) {
    self.host = host
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let params = args as? [String: Any]
    let playerId = params?["playerId"] as? String ?? ""
    guard let host = host else {
      // No host means registration failed; an empty black view is better than
      // a crash, and the Dart side will have failed its session open already.
      return TGMediaEmptyView(frame: frame)
    }
    return TGMediaPlayerView(frame: frame, playerId: playerId, host: host)
  }
}

final class TGMediaEmptyView: NSObject, FlutterPlatformView {
  private let container: UIView

  init(frame: CGRect) {
    container = UIView(frame: frame)
    container.backgroundColor = .black
    super.init()
  }

  func view() -> UIView { container }
}
