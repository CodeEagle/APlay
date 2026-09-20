//
//  ConfigurationTests.swift
//
//  Defaults, policies and builder injection for `APlay.Configuration`. The
//  configuration object is what every component reads its behaviour from, so
//  the default values and the policy enums are pinned down here.
//

import XCTest
@testable import APlay

final class ConfigurationTests: XCTestCase {

    // MARK: - Logger.Policy

    func testLoggerPolicy() {
        XCTAssertTrue(Logger.Policy.disable.isDisabled)
        XCTAssertNil(Logger.Policy.disable.folder)
        let policy = Logger.Policy.persistentInFolder("/tmp/APlayConfigTests")
        XCTAssertFalse(policy.isDisabled)
        XCTAssertEqual(policy.folder, "/tmp/APlayConfigTests")
    }

    func testLoggerDefaultPolicyCreatesFolder() throws {
        let folder = try XCTUnwrap(Logger.Policy.defaultPolicy.folder)
        XCTAssertTrue(folder.contains("/APlay/Log"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder),
                      "the default policy must create its log folder")
    }

    func testLoggerChannelSymbols() {
        XCTAssertEqual(Logger.Channel.audioDecoder.symbole, "🌈")
        XCTAssertEqual(Logger.Channel.streamProvider.symbole, "🌊")
        XCTAssertEqual(Logger.Channel.metadataParser.symbole, "⚡️")
        XCTAssertEqual(Logger.Channel.player.symbole, "🍵")
        // Every channel needs a symbol; an empty one would silently drop the
        // channel prefix from the log.
        for channel in Logger.Channel.allCases {
            XCTAssertFalse(channel.symbole.isEmpty)
        }
    }

    // MARK: - InternalLogger

    func testInternalLoggerWritesToItsFolder() {
        let folder = "\(NSTemporaryDirectory())APlayConfigLoggerTests"
        let fm = FileManager.default
        // A custom policy does not create its folder; the app owns that.
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let logger = APlay.InternalLogger(policy: Logger.Policy.persistentInFolder(folder))
        XCTAssertTrue(logger.currentFile.contains(folder), "a persistent logger knows its file")
        XCTAssertTrue(fm.fileExists(atPath: logger.currentFile),
                      "the logger creates its file on init")

        logger.isLoggedToConsole = false
        logger.log("hello", to: .audioDecoder, method: #function)
        logger.reset()
        // `cleanAllLogs` removes the folder and puts it back empty.
        logger.cleanAllLogs()
        XCTAssertTrue(fm.fileExists(atPath: folder))
    }

    func testInternalLoggerWithoutFolderIsInert() {
        let logger = APlay.InternalLogger(policy: .disable)
        XCTAssertEqual(logger.currentFile, "", "a disabled policy has no file")
        logger.log("nowhere", to: .streamProvider, method: #function)
        logger.reset()
        logger.cleanAllLogs()
    }

    // MARK: - HttpFileValidationPolicy

    func testHttpFileValidationPolicyKeys() {
        XCTAssertEqual(APlay.Configuration.HttpFileValidationPolicy.notValidate.keys, [])
        let policy = APlay.Configuration.HttpFileValidationPolicy.validateHeader(keys: ["Content-Length", "Etag"]) { _, _, _ in true }
        XCTAssertEqual(policy.keys, ["Content-Length", "Etag"])
    }

    // MARK: - CacheFileNamingPolicy

    func testCacheFileNamingPolicy() {
        let url = URL(fileURLWithPath: "/a/b.mp3")
        XCTAssertEqual(APlay.Configuration.CacheFileNamingPolicy.default.name(for: url), "_a_b.mp3",
                       "the default names the cache file after the url path")

        let custom = APlay.Configuration.CacheFileNamingPolicy.custom { $0.lastPathComponent }
        XCTAssertEqual(custom.name(for: url), "b.mp3")

        let base64 = APlay.Configuration.CacheFileNamingPolicy.defaultPolicy.name(for: url)
        XCTAssertEqual(base64, "/a/b.mp3".data(using: .utf8)!.base64EncodedString())
    }

    // MARK: - CachePolicy

    func testCachePolicy() {
        XCTAssertTrue(APlay.Configuration.CachePolicy.enable(["a", "b"]).isEnabled)
        XCTAssertEqual(APlay.Configuration.CachePolicy.enable(["a", "b"]).cachedFolder, ["a", "b"])
        XCTAssertFalse(APlay.Configuration.CachePolicy.disable.isEnabled)
        XCTAssertNil(APlay.Configuration.CachePolicy.disable.cachedFolder)
    }

    // MARK: - NetworkPolicy

    func testNetworkPolicyNoRestrict() {
        let expectation = XCTestExpectation(description: "noRestrict grants permission")
        APlay.Configuration.NetworkPolicy.noRestrict.requestPermission(for: URL(string: "https://example.com/a.mp3")!) { granted in
            XCTAssertTrue(granted)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testNetworkPolicyRequiredPermission() {
        let url = URL(string: "https://example.com/a.mp3")!
        let policy = APlay.Configuration.NetworkPolicy.requiredPermission { requestURL, completion in
            XCTAssertEqual(requestURL, url)
            completion(false)
        }
        let expectation = XCTestExpectation(description: "requiredPermission routes to the handler")
        policy.requestPermission(for: url) { granted in
            XCTAssertFalse(granted)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Defaults

    func testDefaultCachedDirectory() {
        let directory = APlay.Configuration.defaultCachedDirectory
        XCTAssertTrue(directory.contains("/APlay/Tmp"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory),
                      "the default cache directory must exist")
    }

    func testDefaultMaxDecodedByteCount() {
        let expected = (MemoryLayout<Int>.size == MemoryLayout<Int64>.size ? 4 : 2) * 1_048_576
        XCTAssertEqual(APlay.Configuration.defaultMaxDecodedByteCount, UInt32(expected))
    }

    func testDefaultUserAgent() {
        let ua = APlay.Configuration.defaultUA
        XCTAssertTrue(ua.contains("APlay/"))
        XCTAssertTrue(ua.contains(APlay.version))
    }

    func testConfigurationDefaults() {
        let config = APlay.Configuration()
        XCTAssertEqual(config.maxDecodedByteCount, APlay.Configuration.defaultMaxDecodedByteCount)
        XCTAssertEqual(config.userAgent, APlay.Configuration.defaultUA)
        XCTAssertEqual(config.cacheDirectory, APlay.Configuration.defaultCachedDirectory)
        XCTAssertEqual(config.logPolicy, Logger.Policy.defaultPolicy)
        XCTAssertEqual(config.decodeBufferSize, 8192)
        XCTAssertEqual(config.startupWatchdogPeriod, 30)
        XCTAssertEqual(config.maxDiskCacheSize, 256_435_456)
        XCTAssertEqual(config.maxRemoteStreamOpenRetry, 5)
        XCTAssertEqual(config.preBufferWaveFormatPercentageBeforePlay, 0.1, accuracy: 0.001)
        XCTAssertTrue(config.cachePolicy.isEnabled)
        XCTAssertEqual(config.cachePolicy.cachedFolder, [])
        XCTAssertEqual(APlay.Configuration.HttpFileValidationPolicy.notValidate.keys, config.httpFileCompletionValidator.keys)
        XCTAssertTrue(config.predefinedHttpHeaderValues.isEmpty)
        XCTAssertTrue(config.isEnabledAutomaticAudioSessionHandling)
        XCTAssertTrue(config.isAutoFillID3InfoToNowPlayingCenter)
        XCTAssertTrue(config.isAutoHandlingInterruptEvent)
        XCTAssertFalse(config.isGaplessPlaybackEnabled)
        XCTAssertTrue(config.isEnabledVolumeMixer)
        XCTAssertTrue(config.isEnabledRemoteCommandHandling)
        XCTAssertEqual(config.equalizerBandFrequencies, [50, 100, 200, 400, 800, 1600, 2600, 16000])
        XCTAssertTrue(config.logger is APlay.InternalLogger)
    }

    // MARK: - Builders

    func testDefaultBuildersProduceTheBuiltInComponents() {
        let config = APlay.Configuration()
        XCTAssertTrue(config.streamerBuilder(config) is Streamer)
        XCTAssertTrue(config.audioDecoderBuilder(config) is DefaultAudioDecoder)
        XCTAssertTrue(config.metadataParserBuilder(.flac, config) is FlacParser)
        XCTAssertTrue(config.metadataParserBuilder(.mp3, config) is ID3Parser)
        XCTAssertNil(config.metadataParserBuilder(.wave, config))
    }

    func testInjectedBuildersAreUsed() throws {
        var streamerCalls = 0
        var decoderCalls = 0
        var parserCalls = 0
        var loggerCalls = 0
        let config = APlay.Configuration(
            logPolicy: .disable,
            loggerBuilder: { policy in
                loggerCalls += 1
                return APlay.InternalLogger(policy: policy)
            },
            streamerBuilder: { configuration in
                streamerCalls += 1
                return Streamer(config: configuration)
            },
            audioDecoderBuilder: { configuration in
                decoderCalls += 1
                return DefaultAudioDecoder(config: configuration)
            },
            metadataParserBuilder: { type, configuration in
                parserCalls += 1
                return type == .flac ? FlacParser(config: configuration) : nil
            })
        XCTAssertEqual(config.logPolicy, Logger.Policy.disable)
        XCTAssertEqual(loggerCalls, 1, "the logger is built eagerly during init")

        _ = config.streamerBuilder(config)
        _ = config.audioDecoderBuilder(config)
        let parser = try XCTUnwrap(config.metadataParserBuilder(.flac, config))
        XCTAssertTrue(parser is FlacParser)
        XCTAssertEqual(streamerCalls, 1)
        XCTAssertEqual(decoderCalls, 1)
        XCTAssertEqual(parserCalls, 1)
        XCTAssertNil(config.metadataParserBuilder(.mp3, config))
        XCTAssertEqual(parserCalls, 2)
    }

    // MARK: - Proxy

    func testProxyPolicyInfo() {
        let info = APlay.Configuration.ProxyPolicy.Info(username: "user",
                                                         password: "pass",
                                                         host: "proxy.example.com",
                                                         port: 8080,
                                                         scheme: .digest)
        XCTAssertEqual(info.username, "user")
        XCTAssertEqual(info.password, "pass")
        XCTAssertEqual(info.host, "proxy.example.com")
        XCTAssertEqual(info.port, 8080)
        XCTAssertFalse(info.isProxyingHttps)
        XCTAssertEqual(String(info.scheme.name), String(kCFHTTPAuthenticationSchemeDigest))
        XCTAssertEqual(String(APlay.Configuration.ProxyPolicy.Info.AuthenticationScheme.basic.name),
                       String(kCFHTTPAuthenticationSchemeBasic))
    }

    func testCustomProxyBuildsAProxiedSession() {
        let info = APlay.Configuration.ProxyPolicy.Info(username: "user",
                                                         password: "pass",
                                                         host: "proxy.example.com",
                                                         port: 8080,
                                                         scheme: .basic,
                                                         proxyingHttps: true)
        XCTAssertTrue(info.isProxyingHttps)
        let config = APlay.Configuration(proxyPolicy: .custom(info), logPolicy: .disable)
        if case let .custom(received) = config.proxyPolicy {
            XCTAssertEqual(received.host, "proxy.example.com")
            XCTAssertEqual(received.port, 8080)
        } else {
            XCTFail("expected a custom proxy policy, got \(config.proxyPolicy)")
        }
        let dictionary = config.session.configuration.connectionProxyDictionary
        XCTAssertNotNil(dictionary)
        XCTAssertEqual(dictionary?.count, 3)
    }

    // MARK: - Background task

    func testBackgroundTaskCallsAreSafeOnMacOS() {
        let config = APlay.Configuration(logPolicy: .disable)
        config.startBackgroundTask()
        config.startBackgroundTask(isToDownloadImage: true)
        config.endBackgroundTask(isToDownloadImage: false)
        config.endBackgroundTask(isToDownloadImage: true)
    }
}
