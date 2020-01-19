@_exported import AVFoundation
@_exported import Combine
@_exported import Dispatch
@_exported import Foundation

#if canImport(UIKit)
    @_exported import UIKit
    public typealias APlayImage = UIImage
#elseif canImport(AppKit)
    @_exported import AppKit
    public typealias APlayImage = NSImage
#endif

/// (ConfigurationCompatible) -> StreamProviderCompatible
public typealias StreamerBuilder = (ConfigurationCompatible) -> StreamProviderCompatible

/// (ConfigurationCompatible) -> AudioDecoderCompatible
public typealias AudioDecoderBuilder = (ConfigurationCompatible) -> AudioDecoderCompatible

/// (Logger.Policy) -> LoggerCompatible
public typealias LoggerBuilder = (Logger.Policy) -> LoggerCompatible

/// (AudioFileType, ConfigurationCompatible) -> MetadataParserCompatible?
public typealias MetadataParserBuilder = (AudioFileType, ConfigurationCompatible) -> MetadataParserCompatible?

/// (APlay.Configuration.ProxyPolicy) -> URLSessionDelegate
public typealias SessionDelegateBuilder = (APlay.Configuration.ProxyPolicy) -> URLSessionDelegate

/// (APlay.Configuration.ProxyPolicy) -> URLSession
public typealias SessionBuilder = (APlay.Configuration.ProxyPolicy) -> URLSession
