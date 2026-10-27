import AVFoundation
import Foundation

/// `AVAssetResourceLoaderDelegate` over a growing TDLib file.
///
/// What this replaces: the V1 loopback HTTP proxy. That had to express every
/// AVPlayer range as a status line plus `Content-Range`/`Content-Length`, and
/// three device failures came from that translation alone (a 206 that declared
/// 659 MB and carried 2 MB, a tail probe that ended the head response, a
/// duplicate tail that stole the download window). Here AVFoundation hands over
/// an offset and a length, and receives bytes — repeatedly, as the file grows.
///
/// The three rules this file keeps:
/// 1. the current EOF is not the real EOF: a request past the downloaded prefix
///    waits, it does not finish;
/// 2. `respond(with:)` may be called many times for one request;
/// 3. a cancelled request stops touching the player immediately.
final class TGMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  /// 512 KB per `respond`. Big enough that a 4 GB film is not four million
  /// channel calls, small enough that a seek is felt within a frame or two.
  private static let chunkBytes: Int64 = 512 * 1024

  /// Poll interval while the file is still growing. 100 ms is one display
  /// frame's worth of patience at 10 Hz — fast enough that growth is picked up
  /// immediately, slow enough not to spin a core.
  private static let pollSeconds: TimeInterval = 0.1

  private let session: TGMediaSession
  private weak var host: TGMediaStreamingHost?
  private let queue: DispatchQueue

  /// Requests AVFoundation told us it no longer wants. `didCancel` is the only
  /// cancellation signal that exists on every iOS version this app supports,
  /// so it is the one that decides when a pump stops.
  private let cancelLock = NSLock()
  private var cancelled = Set<ObjectIdentifier>()

  init(session: TGMediaSession, host: TGMediaStreamingHost?) {
    self.session = session
    self.host = host
    self.queue = DispatchQueue(
      label: "tgmedia.resourceloader.\(session.id)",
      qos: .userInitiated,
      attributes: .concurrent
    )
    super.init()
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    if let info = loadingRequest.contentInformationRequest {
      // The whole contract with AVFoundation, in four lines. `contentLength`
      // is TDLib's total size — the file length, not what exists on disk.
      info.contentType = session.contentType
      info.contentLength = session.totalBytes
      info.isByteRangeAccessSupported = true
      // Only a finished download is fully available. Claiming otherwise for a
      // growing file is what makes AVPlayer read past EOF, give up, and report
      // "无法连接服务器".
      info.isEntireLengthAvailableOnDemand = session.completed
      host?.emit(type: "contentInfo", session: session, extra: [
        "total": session.totalBytes,
        "contentType": session.contentType,
        "completed": session.completed,
      ])
    }

    guard let dataRequest = loadingRequest.dataRequest else {
      loadingRequest.finishLoading()
      return true
    }

    host?.emit(type: "dataRequest", session: session, extra: [
      "offset": dataRequest.requestedOffset,
      "length": dataRequest.requestedLength,
      "currentOffset": dataRequest.currentOffset,
      "allToEnd": dataRequest.requestsAllDataToEndOfResource,
    ])

    queue.async { [weak self] in
      self?.pump(loadingRequest: loadingRequest, dataRequest: dataRequest)
    }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    cancelLock.lock()
    cancelled.insert(ObjectIdentifier(loadingRequest))
    cancelLock.unlock()
    host?.emit(type: "cancelled", session: session, extra: [
      "offset": loadingRequest.dataRequest?.currentOffset ?? -1,
    ])
  }

  private func isCancelled(_ request: AVAssetResourceLoadingRequest) -> Bool {
    cancelLock.lock()
    let flag = cancelled.contains(ObjectIdentifier(request))
    cancelLock.unlock()
    return flag
  }

  /// Serves one loading request until it is satisfied, cancelled, or the supply
  /// reports a terminal condition.
  ///
  /// A 700 MB request against a 20 MB prefix is *normal* for a moov-at-end
  /// file: the loop hands over the 20 MB, then waits for the download to grow
  /// and keeps going. It never finishes early with a short body.
  private func pump(
    loadingRequest: AVAssetResourceLoadingRequest,
    dataRequest: AVAssetResourceLoadingDataRequest
  ) {
    let total = session.totalBytes
    let start = dataRequest.requestedOffset
    let requested = dataRequest.requestedLength

    // End of what the player wants, exclusive. `requestsAllDataToEndOfResource`
    // means "everything from here on" — for a growing file that is the total
    // size, which is known from the file record.
    var endExclusive: Int64
    if dataRequest.requestsAllDataToEndOfResource {
      endExclusive = total > 0 ? total : Int64.max
    } else if total > 0 {
      endExclusive = min(total, start &+ requested)
    } else {
      endExclusive = start &+ requested
    }
    if endExclusive < start { endExclusive = start }

    var servedBytes: Int64 = 0
    var idlePolls = 0
    var lastOffset = start
    var waitingReported = 0

    while !isCancelled(loadingRequest) && !session.isClosed {
      if isCancelled(loadingRequest) || session.isClosed { break }
      let offset = dataRequest.currentOffset
      if offset >= endExclusive { break }

      var want = TGMediaResourceLoader.chunkBytes
      if endExclusive != Int64.max {
        want = min(want, endExclusive - offset)
      }
      if want <= 0 { break }

      let reading = session.supply(offset: offset, length: want)

      if let code = reading.errorCode {
        host?.emit(type: "supplyError", session: session, extra: [
          "code": code,
          "message": reading.errorMessage ?? "",
          "offset": offset,
          "served": servedBytes,
        ])
        loadingRequest.finishLoading(
          with: NSError(
            domain: "tgmedia.resourceloader",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reading.errorMessage ?? code]
          )
        )
        return
      }

      if reading.hasData {
        let available = reading.to - offset + 1
        let length = min(want, available)
        if length > 0,
           let data = TGMediaFileReader.read(
             path: reading.path, offset: offset, length: length),
           !data.isEmpty {
          // The player may have cancelled while the read was in flight; a
          // respond after cancellation raises.
          if isCancelled(loadingRequest) { break }
          dataRequest.respond(with: data)
          servedBytes += Int64(data.count)
          idlePolls = 0
          waitingReported = 0
          continue
        }
      }

      // Nothing readable at `offset` yet. If this request moved (the player
      // asked for a newer offset on the same object), it is not a stall.
      if offset != lastOffset {
        lastOffset = offset
        idlePolls = 0
      }
      idlePolls += 1
      if idlePolls == 5 || (idlePolls % 100 == 0) {
        waitingReported += 1
        host?.emit(type: "waiting", session: session, extra: [
          "offset": offset,
          "waitedMs": reading.waitingMillis,
          "downloading": reading.downloading,
          "poll": waitingReported,
        ])
      }
      Thread.sleep(forTimeInterval: TGMediaResourceLoader.pollSeconds)
    }

    let cancelledNow = isCancelled(loadingRequest)
    host?.emit(type: cancelledNow ? "requestCancelled" : "requestFinished",
                session: session,
                extra: ["served": servedBytes, "from": start])
    if !cancelledNow {
      loadingRequest.finishLoading()
    }

    cancelLock.lock()
    cancelled.remove(ObjectIdentifier(loadingRequest))
    cancelLock.unlock()
  }
}

/// Reads bytes out of a file that is still being written.
///
/// A fresh handle per read on purpose: TDLib appends to the same inode from
/// another thread, and a cached handle would keep its own idea of the length.
/// `readData(ofLength:)` simply returns what exists, so a read that runs past
/// the current EOF returns short data instead of throwing.
enum TGMediaFileReader {
  static func read(path: String, offset: Int64, length: Int64) -> Data? {
    guard length > 0, offset >= 0, !path.isEmpty else { return nil }
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: UInt64(offset))
      return handle.readData(ofLength: Int(length))
    } catch {
      return nil
    }
  }
}
