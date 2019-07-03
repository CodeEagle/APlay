import os.log
import Combine

// MARK: - Downloader
public final class Downloader: NSObject {
    static let logger = OSLog(subsystem: "com.selfstudio.aplay.downloader", category: "Downloader")
    public private(set) var session: URLSession = URLSession(configuration: .default)
    public private(set) var delegator: URLSessionDelegator = .init()
    private var _task: URLSessionDataTask?
    private unowned let _configuration: ConfigurationCompatible
    private var _data: Data = .init()
    @Published private var _event: Event = .idle
    
    public var eventPipeline: AnyPublisher<Event, Never> { $_event.eraseToAnyPublisher() }
    
    deinit {
        guard _task != nil else { return }
        cancel()
    }
    
    public init(configuration: ConfigurationCompatible) {
        self._configuration = configuration
        super.init()
        let s = configuration.session
        session = URLSession(configuration: s.configuration, delegate: delegator, delegateQueue: nil)
        
        _ = delegator.eventPublisher.sink(receiveValue: { [weak self] event in
            guard let sself = self else { return }
            switch event {
            case let .completed(err):
                let result: Result<Data, Error>
                if let e = err {
                    result = .failure(e)
                } else {
                    result = .success(sself._data)
                }
                sself._task = nil
                sself._event = .completed(result)
                
            case .initialize, .onResponse, .onStartPostition: break
            case let .onTotalByte(v): sself._event = .onTotalByte(v)
            case let .onReceiveByte(v): sself._event = .onAvailableLength(v)
            case let .onData(v):
                sself._event = .onData(v)
                sself._data.append(v)
                
            case let .onProgress(v): sself._event = .onProgress(v)
            }
        })
    }
}

// MARK: - Download
public extension Downloader {
    
    func download(_ resource: URL, at position: UInt64 = 0) {
        delegator.download(resource, at: position)
        var request = URLRequest(url: resource, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        if position > 0 {
            request.addValue("bytes=\(position)-", forHTTPHeaderField: "Range")
        }
        _event = .onStartPosition(position)
        _event = .onRequest(request)
        _task = session.dataTask(with: request)
        resume()
    }
    
    func cancel() {
        _task?.cancel()
        _task = nil
        _event = .onCancel
    }
    
    func suspend() {
        _task?.suspend()
        _event = .onSuspend
    }
    
    func resume() {
        _task?.resume()
        _event = .onResume
    }
}

// MARK: - Enum
extension Downloader {
    public enum Event {
        case idle
        case onRequest(URLRequest)
        case onStartPosition(UInt64)
        case onTotalByte(UInt64)
        case onAvailableLength(UInt64)
        case onData(Data)
        case onProgress(Float)
        case onCancel
        case onSuspend
        case onResume
        case completed(Result<Data, Error>)
    }
}


// MARK: - URLSessionDelegator
public final class URLSessionDelegator: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    
    @Published private var _event: Event = .initialize
    public var passthrougthDelegate: URLSessionDataDelegate?
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
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        os_log("%@ - %d: receive response: %@", log: Downloader.logger, type: .debug, #function, #line, response)
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
        os_log("%@ - %d: didReceive data: %d", log: Downloader.logger, type: .debug, #function, #line, data.count)
        let dataCount = UInt64(data.count)
        currentTaskReceivedTotalBytes += dataCount
        event = .onReceiveByte(currentTaskReceivedTotalBytes)
        event = .onData(data)
        let total = Float(totalBytes)
        guard total.isNaN == false, total.isZero == false else { return }
        event = .onProgress(Float(currentTaskReceivedTotalBytes) / total)
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Swift.Error?) {
        os_log("%@ - %d: didCompleteWithError: %@", log: Downloader.logger, type: .debug, #function, #line, String.init(describing: error))
        event = .completed(error)
    }
}

// MARK: - Public API
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

// MARK: - Enum
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
