import Combine

public final class Composer {
    public private(set) var downloader: Downloader
    public private(set) var streamer: Streamer
    public private(set) var urlInfo: StreamProvider.URLInfo = .default
    public var progressPublisher: AnyPublisher<URLSessionDelegator.Info, Never> { _progressSubject.eraseToAnyPublisher() }
    public var progress: URLSessionDelegator.Info { _progressSubject.value }

    private var _progressSubject: CurrentValueSubject<URLSessionDelegator.Info, Never> = .init(.default)
    private unowned let _configuration: ConfigurationCompatible
    private var _resourceManager: ResourcesManager
    private var _sownloadSubscriber: AnyCancellable?
    private var _urlReponse: URLResponse?
    private lazy var _retryCount: UInt = 0

    deinit { _sownloadSubscriber?.cancel() }

    public init(configuration: ConfigurationCompatible) {
        let resMan: ResourcesManager = .init(configuration: configuration)
        downloader = .init(configuration: configuration)
        streamer = .init(configuration: configuration, dataReader: resMan)
        _configuration = configuration
        _resourceManager = resMan
        addDownloadEventHandler()
    }

    func addDownloadEventHandler() {
        let val = downloader.eventPipeline.sink { [weak self] (event) in
            guard let sself = self else { return }
            switch event {

            case let .onResponse(resp):
                sself._urlReponse = resp

            case let .onTotalByte(len):
                sself.urlInfo.remoteContentLength = len
                sself._resourceManager.readWritePipeline.targetFileLength = len - sself.urlInfo.startPosition
                
            case let .onData(data, info):
                sself._resourceManager.write(data: data)
                sself._progressSubject.send(info)

            case let .completed(result):
                switch result {
                case let .failure(e):
                    let r = sself._configuration.retryPolicy.canRetry(with: e, count: sself._retryCount)
                    if r.0 == true {
                        DispatchQueue.main.asyncAfter(deadline: .now() + r.1) { [weak self] in
                            guard let sself = self else { return }
                            sself.downloader.download(sself.urlInfo)
                            sself._retryCount = sself._retryCount.addingReportingOverflow(1).partialValue
                        }
                    }

                case let .success(data):
                    guard sself.urlInfo != .default,
                        let resp = sself._urlReponse,
                        sself._configuration.remoteDataVerifyPolicy.verify(response: resp, data: data) else { return }
                    FileManager.copyItemByStripingTmpSuffix(at: sself._resourceManager.storePath)
                }
            default: break
            }
        }
        _sownloadSubscriber = AnyCancellable(val)
    }
}

public extension Composer {
    func play(_ url: URL, at position: StreamProvider.Position = 0, info: AudioDecoder.Info? = nil) throws {
        urlInfo = try _resourceManager.updateResource(for: url, at: position)
        if urlInfo.hasLocalCached {
            print("local file: \(urlInfo)")
        } else {
            downloader.download(urlInfo)
        }
    }
}
