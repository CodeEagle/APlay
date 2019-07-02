import os.log
import Combine

public final class Downloader {
    static let logger = OSLog(subsystem: "com.selfstudio.aplay.downloader", category: "Downloader")
    public private(set) var session: URLSession = URLSession.shared
    public private(set) var delegator: URLSessionDelegator = .init()
    private var _task: URLSessionDownloadTask?
    
    deinit {
        _task?.cancel()
    }
    
    public init(config: URLSessionConfiguration = URLSession.shared.configuration) {
        session = URLSession(configuration: config, delegate: delegator, delegateQueue: nil)
        _ = delegator.eventPublisher.sink(receiveCompletion: { (result) in
            
        }, receiveValue: { event in
            
        })
    }
}

public extension Downloader {
    
    func download(_ resource: URL, at position: UInt64 = 0) {
        delegator.download(resource, at: position)
        session.downloadTask(with: resource)
    }
}

public final class URLSessionDelegator: NSObject {
    
    @Published private var _event: Event = .initialize
    private var _startPosition: UInt64 = 0
    private var _totalBytes: UInt64 = 0
    private var _currentTaskTotalBytes: UInt64 = 0
    private var _currentTaskReceivedTotalBytes: UInt64 = 0
    private var _queue: DispatchQueue = DispatchQueue(concurrentName: "URLSessionDelegator")
    
    private func reset() {
        event = .initialize
        startPosition = 0
        totalBytes = 0
        currentTaskTotalBytes = 0
        currentTaskReceivedTotalBytes = 0
    }
    
    public func download(_ resource: URL, at position: UInt64 = 0) {
        reset()
        startPosition = position
        event = .onStartPostition(position)
    }
}

extension URLSessionDelegator {
    public private(set) var event: Event {
        get { return _queue.sync { _event } }
        set { _queue.async(flags: .barrier) { self._event = newValue } }
    }
    
    public private(set) var startPosition: UInt64 {
        get { return _queue.sync { _startPosition } }
        set { _queue.async(flags: .barrier) { self._startPosition = newValue } }
    }
    
    public private(set) var totalBytes: UInt64 {
        get { return _queue.sync { _totalBytes } }
        set { _queue.async(flags: .barrier) { self._totalBytes = newValue } }
    }
    
    public private(set) var currentTaskTotalBytes: UInt64 {
        get { return _queue.sync { _currentTaskTotalBytes } }
        set { _queue.async(flags: .barrier) { self._currentTaskTotalBytes = newValue } }
    }
    
    public private(set) var currentTaskReceivedTotalBytes: UInt64 {
        get { return _queue.sync { _currentTaskReceivedTotalBytes } }
        set { _queue.async(flags: .barrier) { self._currentTaskReceivedTotalBytes = newValue } }
    }
    
    public var eventPublisher: AnyPublisher<Event, Never> {
        return $_event.eraseToAnyPublisher()
    }
}

extension URLSessionDelegator {
    public enum Event {
        case initialize
        case onResponse(URLResponse)
        case onTotalByte(UInt64)
        case onStartPostition(UInt64)
        case onReceiveByte(UInt64)
        case onData(Data)
        case onProgress(Float)
        case completed(Error?)
    }
}

extension URLSessionDelegator: URLSessionDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        os_log("%@ - %d", log: Downloader.logger, type: .debug, #function, #line)
        let totalLength = UInt64(response.expectedContentLength)
        if let resp = response as? HTTPURLResponse {
            _queue.async(flags: .barrier) {
                if resp.statusCode == 200 {
                    self._totalBytes = totalLength
                } else if resp.statusCode == 206 {
                    self._currentTaskTotalBytes = totalLength
                    self._totalBytes = totalLength + self._startPosition
                }
            }
        }
        completionHandler(.allow)
        event = .onResponse(response)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        os_log("%@ - %d", log: Downloader.logger, type: .debug, #function, #line, data.count)
        let dataCount = UInt64(data.count)
        currentTaskReceivedTotalBytes += dataCount
        event = .onReceiveByte(currentTaskReceivedTotalBytes)
        event = .onData(data)
        event = .onProgress(Float(currentTaskReceivedTotalBytes) / Float(totalBytes))
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        os_log("%@ - %d", log: Downloader.logger, type: .debug, #function, #line)
        event = .completed(error)
    }
}
