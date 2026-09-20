//
//  ExtensionTests.swift
//
//  The utility extensions in `APlay+Extensions.swift`, the `AudioFileType`
//  wrapper and `GCDTimer`'s value semantics: pure functions and small value
//  types, so every branch is pinned with a direct call instead of through the
//  player stack.
//

import XCTest
import AVFoundation
import CoreAudio
@testable import APlay

final class ExtensionTests: XCTestCase {

    // MARK: - AudioStreamBasicDescription

    func testAudioStreamBasicDescriptionEquality() {
        let pcm = AudioStreamBasicDescription(mSampleRate: 44100,
                                              mFormatID: CoreAudio.kAudioFormatLinearPCM,
                                              mFormatFlags: 0,
                                              mBytesPerPacket: 4,
                                              mFramesPerPacket: 1,
                                              mBytesPerFrame: 4,
                                              mChannelsPerFrame: 2,
                                              mBitsPerChannel: 16,
                                              mReserved: 0)
        XCTAssertEqual(pcm, pcm)
        XCTAssertTrue(pcm.isLinearPCM)

        var twin = pcm
        XCTAssertEqual(twin, pcm)
        twin.mSampleRate = 48000
        XCTAssertNotEqual(twin, pcm, "a changed sample rate must break equality")

        twin = pcm
        twin.mChannelsPerFrame = 1
        XCTAssertNotEqual(twin, pcm)

        let aac = AudioStreamBasicDescription(mSampleRate: 44100,
                                              mFormatID: kAudioFormatMPEG4AAC,
                                              mFormatFlags: 0,
                                              mBytesPerPacket: 0,
                                              mFramesPerPacket: 1024,
                                              mBytesPerFrame: 0,
                                              mChannelsPerFrame: 2,
                                              mBitsPerChannel: 0,
                                              mReserved: 0)
        XCTAssertFalse(aac.isLinearPCM)
        XCTAssertNotEqual(aac, pcm)
    }

    // MARK: - Array

    func testArraySafeSubscript() {
        let array = [1, 2, 3]
        XCTAssertEqual(array[ap_safe: 0], 1)
        XCTAssertEqual(array[ap_safe: 2], 3)
        XCTAssertNil(array[ap_safe: 3], "one past the end must be nil")
        XCTAssertNil(array[ap_safe: -1], "negative index must be nil")
        XCTAssertNil([Int]()[ap_safe: 0])
    }

    // MARK: - DispatchQueue

    func testDispatchQueueLabelPrefix() {
        XCTAssertEqual(DispatchQueue(name: "X").label, "com.SelfStudio.APlay.X")
        XCTAssertEqual(DispatchQueue(concurrentName: "Y").label, "com.SelfStudio.APlay.Y")
    }

    // MARK: - URL

    func testURLAsCFunctionString() {
        XCTAssertEqual(URL(fileURLWithPath: "/a/b.mp3").asCFunctionString(), "/a/b.mp3")
        // A `file://` URL keeps its percent encoding, which the C APIs do not
        // want, so it is decoded as well as stripped.
        XCTAssertEqual(URL(fileURLWithPath: "/a b.mp3").asCFunctionString(), "/a b.mp3")
        // A path that literally contains "%20" is left alone: `url.path` does
        // not decode it, and the round trip must not invent a space.
        XCTAssertEqual(URL(fileURLWithPath: "/a%20b.mp3").asCFunctionString(), "/a%20b.mp3")
    }

    // MARK: - UnsafeMutableRawPointer

    func testPointerIdentityRoundtrip() {
        let object = NSObject()
        let opaque = UnsafeMutableRawPointer.from(object: object)
        XCTAssertTrue(opaque.to(object: NSObject.self) === object, "roundtrip must return the very same instance")
    }

    func testUInt8PointerAllocation() {
        let pointer = UnsafeMutablePointer<UInt8>.uint8Pointer(of: 4)
        pointer[0] = 0xDE
        pointer[3] = 0xAD
        XCTAssertEqual(pointer[0], 0xDE)
        XCTAssertEqual(pointer[1], 0)
        XCTAssertEqual(pointer[3], 0xAD)
        pointer.deallocate()
    }

    // MARK: - AudioFileStreamParseFlags

    func testAudioFileStreamParseFlagsContinuity() {
        XCTAssertEqual(AudioFileStreamParseFlags.continuity.rawValue, 0)
    }

    // MARK: - OSStatus

    func testOSStatusReadableMessage() {
        XCTAssertEqual(OSStatus(0).readableMessage(from: "fmt?"),
                       "Audio File Unsupported Data Format(fmt?)")
        XCTAssertEqual(OSStatus(0).readableMessage(from: "wht?"),
                       "Audio File Unspecified(wht?)")
        XCTAssertEqual(OSStatus(0).readableMessage(from: "-39"),
                       "Audio File End Of File Error(-39)")
        XCTAssertEqual(OSStatus(0).readableMessage(from: "(nope)"), "((nope))",
                       "unknown four-char codes fall back to the raw payload, wrapped in parens")
    }

    func testOSStatusCheck() {
        XCTAssertNil(OSStatus(noErr).check(), "noErr is not an error")

        let message = OSStatus(1718449215).check(operation: "decode") // 'fmt?'
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("Audio File Unsupported Data Format(fmt?)"))
        XCTAssertTrue(message!.contains("operation: decode"))
        XCTAssertTrue(message!.contains("message:"))
    }

    func testOSStatusCheckOnNegativeCode() {
        // Negative statuses are not printable four-char codes, so they are
        // rendered numerically and still translated.
        let message = OSStatus(-38).check()
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("Audio File Not Open(-38)"))
    }

    func testOSStatusThrowCheck() throws {
        try OSStatus(noErr).throwCheck()
        XCTAssertThrowsError(try OSStatus(1718449215).throwCheck()) { error in
            guard case APlay.Error.player = error else {
                return XCTFail("expected APlay.Error.player, got \(error)")
            }
        }
    }

    func testOSStatusEmpty() {
        XCTAssertEqual(OSStatus.empty, 101)
    }

    // MARK: - AudioFileType

    func testAudioFileTypeFromAudioFileTypeID() {
        XCTAssertEqual(AudioFileType(value: 0x4D504733), .mp3, "0x4D504733 is 'MPG3'")
        XCTAssertEqual(AudioFileType(value: 0x666C6163), .flac, "0x666C6163 is 'flac'")
        XCTAssertNil(AudioFileType(value: 0xFFFFFFFF), "0xFFFFFFFF is not valid UTF-8")
    }

    func testStringFromUInt32() {
        XCTAssertEqual(String(from: 0x4D504733), "MPG3")
        XCTAssertEqual(String(from: 0x666C6163), "flac")
        XCTAssertNil(String(from: 0xFFFFFFFF))
    }

    func testAudioFileTypeIDConversion() {
        XCTAssertEqual(AudioFileType.mp3.audioFileTypeID, 0x4D504733)
        // A second lookup goes through the static map cache.
        XCTAssertEqual(AudioFileType.mp3.audioFileTypeID, 0x4D504733)
        XCTAssertEqual(AudioFileType.flac.audioFileTypeID, 0x666C6163)
        XCTAssertNotEqual(AudioFileType.mp3.audioFileTypeID, AudioFileType.flac.audioFileTypeID)
        XCTAssertNotEqual(AudioFileType.mp3.audioFileTypeID, AudioFileType.wave.audioFileTypeID)
    }

    // MARK: - GCDTimer

    func testGCDTimerHashable() {
        let timer = GCDTimer(interval: .seconds(3600)) { _ in }
        XCTAssertEqual(timer, timer)

        // `GCDTimer` equality is per-instance, so two timers are never equal
        // even with identical configuration.
        let other = GCDTimer(interval: .seconds(3600)) { _ in }
        XCTAssertNotEqual(timer, other)

        var set: Set<GCDTimer> = [timer, timer, other]
        XCTAssertEqual(set.count, 2, "the set must deduplicate by identity")
        XCTAssertTrue(set.contains(timer))

        // Balance the internal suspend/resume bookkeeping before release.
        set.forEach { $0.invalidate() }
        set.removeAll()
    }

    func testGCDTimerPauseResumeLifecycle() {
        let timer = GCDTimer(interval: .seconds(3600)) { _ in }
        timer.resume()
        timer.pause()
        // `invalidate` clears the handler and pauses; the deinit then resumes
        // exactly once, so a stopped timer must be invalidated, not resumed.
        timer.invalidate()
    }
}
