import SwiftUI
import UIKit

/// Reads the coordinator's multipart MJPEG stream and publishes the latest frame.
/// Frames are split on JPEG start/end markers, like pi/dorme_coord/peripherals.JpegSplitter.
@MainActor
@Observable
final class MJPEGStream {
    enum Status: Equatable { case idle, loading, playing, failed(String) }

    private(set) var image: UIImage?
    private(set) var status: Status = .idle
    private(set) var lastFrameAt: Date?

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var task: URLSessionDataTask?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var delegate: Delegate?

    func start(_ request: URLRequest) {
        stop()
        status = .loading
        let delegate = Delegate()
        delegate.onData = { [weak self] data in self?.consume(data) }
        delegate.onEnd = { [weak self] message in
            guard let self else { return }
            if self.status != .idle { self.status = .failed(message) }
        }
        self.delegate = delegate
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: .main)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }

    func stop() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        buffer.removeAll()
        status = .idle
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let start = buffer.range(of: Data([0xFF, 0xD8])) {
            if start.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start.lowerBound) }
            guard let end = buffer.range(of: Data([0xFF, 0xD9]), in: buffer.index(buffer.startIndex, offsetBy: 2)..<buffer.endIndex) else {
                if buffer.count > 3_000_000 { buffer.removeAll() }
                return
            }
            let frame = buffer.subdata(in: buffer.startIndex..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            if let img = UIImage(data: frame) {
                image = img
                lastFrameAt = Date()
                status = .playing
            }
        }
        if buffer.count > 3_000_000 { buffer.removeAll() }
    }

    private final class Delegate: NSObject, URLSessionDataDelegate {
        var onData: (@MainActor (Data) -> Void)?
        var onEnd: (@MainActor (String) -> Void)?

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                completionHandler(.allow)
            } else {
                completionHandler(.cancel)
                let message = code == 503 ? "Camera unavailable on the robot." : "Camera stream refused (\(code))."
                MainActor.assumeIsolated { onEnd?(message) }
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            MainActor.assumeIsolated { onData?(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let message = error.map { _ in "Camera stream ended." } ?? "Camera stream ended."
            MainActor.assumeIsolated { onEnd?(message) }
        }
    }
}
