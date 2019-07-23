import Combine

public final class Composer {
    public private(set) var downloader: Downloader
    public private(set) var streamer: Streamer
    public private(set) var urlInfo: StreamProvider.URLInfo = .none
    
    private unowned let _configuration: ConfigurationCompatible
    private var _resourceManager: ResourcesManager
    private var _sownloadSubscriber: Subscribers.Sink<Downloader.Event, Never>?
    
    deinit {
        _sownloadSubscriber?.cancel()
    }
    
    public init(configuration: ConfigurationCompatible) {
        _configuration = configuration
        downloader = .init(configuration: configuration)
        streamer = .init(configuration: configuration)
        _resourceManager = .init(configuration: configuration)
        addDownloadEventHandler()
    }
    
    func addDownloadEventHandler() {
        _sownloadSubscriber = downloader.eventPipeline.sink { [weak self] (event) in
            guard let sself = self else { return }
            switch event {
            case let .onResponse(resp):
                print(resp)
            case let .onData(data, info):
//                if info.progress >= 0.6 {
//                    exit(0);
//                }
                sself._resourceManager.write(data: data)
            case .completed:
                print(sself._resourceManager.storePath)
            default: break
            }
        }
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
