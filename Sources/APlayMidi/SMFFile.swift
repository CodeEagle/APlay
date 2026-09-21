//
//  SMFFile.swift
//  APlayMidi
//
//  A minimal Standard MIDI File reader. The wrapper only needs two things
//  from the file up front — that it *is* an SMF, and its duration in seconds
//  (so the pipeline's duration bar and end detection work). Rendering itself
//  is delegated to `AVAudioSequencer`.
//
//  Handles running status, meta events (tempo, end-of-track) and both
//  quarter-note and SMPTE divisions. A malformed file yields `nil` so the
//  decoder can report a parser error instead of misbehaving.
//

import Foundation

struct SMFFile {
    /// Total playback time in seconds, from the last event of any track.
    let duration: TimeInterval

    init?(data: Data) {
        guard data.count >= 14 else { return nil }
        guard data.prefix(4) == Data("MThd".utf8) else { return nil }

        var cursor = 4
        guard let headerLength = Self.readUInt32(data, &cursor), headerLength >= 6 else { return nil }
        guard let format = Self.readUInt16(data, &cursor) else { return nil }
        guard let trackCount = Self.readUInt16(data, &cursor) else { return nil }
        guard let division = Self.readUInt16(data, &cursor) else { return nil }
        _ = format

        // Negative division is SMPTE: frames/sec in the high byte, ticks per
        // frame in the low one. Everything else is ticks per quarter note.
        let ticksPerQuarter: Double
        let smpteFrameRate: Double
        let ticksPerFrame: Double
        if division & 0x8000 != 0 {
            ticksPerQuarter = 0
            smpteFrameRate = -Double(Int16(bitPattern: division) >> 8)
            ticksPerFrame = Double(division & 0x00FF)
        } else {
            ticksPerQuarter = Double(division)
            smpteFrameRate = 0
            ticksPerFrame = 0
        }
        guard ticksPerQuarter > 0 || (smpteFrameRate > 0 && ticksPerFrame > 0) else { return nil }

        // Tempo changes keyed by the absolute tick they occur at. The SMF
        // default is 120 BPM (500 000 µs per quarter).
        var tempoEvents: [(tick: Double, microsecondsPerQuarter: Double)] = []
        var trackEndTicks: [Double] = []

        var remainingTracks = Int(trackCount)
        while remainingTracks > 0 {
            guard cursor + 8 <= data.count,
                  data[cursor..<cursor + 4] == Data("MTrk".utf8) else { return nil }
            cursor += 4
            guard let trackLength = Self.readUInt32(data, &cursor) else { return nil }
            let trackEnd = cursor + Int(trackLength)
            guard trackEnd <= data.count else { return nil }

            var tick: Double = 0
            var runningStatus: UInt8 = 0
            var reachedEnd = false
            while cursor < trackEnd && !reachedEnd {
                guard let delta = Self.readVarLen(data, &cursor, limit: trackEnd) else { return nil }
                tick += Double(delta)

                guard cursor < trackEnd else { break }
                var status = data[cursor]
                if status < 0x80 {
                    // A data byte first: the previous channel status still stands.
                    if runningStatus == 0 { return nil }
                    status = runningStatus
                } else {
                    cursor += 1
                    if status >= 0x80 && status <= 0xEF { runningStatus = status }
                    else { runningStatus = 0 }       // system/reset messages carry no status
                }

                switch status {
                case 0xFF:
                    guard cursor < trackEnd else { return nil }
                    let metaType = data[cursor]
                    cursor += 1
                    guard let length = Self.readVarLen(data, &cursor, limit: trackEnd) else { return nil }
                    let payloadEnd = cursor + Int(length)
                    guard payloadEnd <= trackEnd else { return nil }
                    if metaType == 0x51, length >= 3 {
                        let micro = Double(Self.beat24(data, cursor))
                        tempoEvents.append((tick, micro))
                    }
                    if metaType == 0x2F { reachedEnd = true }
                    cursor = payloadEnd
                case 0xF0, 0xF7:
                    // System exclusive: a length-prefixed blob, no running status.
                    guard let length = Self.readVarLen(data, &cursor, limit: trackEnd) else { return nil }
                    guard cursor + Int(length) <= trackEnd else { return nil }
                    cursor += Int(length)
                case 0xF1, 0xF3:
                    guard cursor + 1 <= trackEnd else { return nil }
                    cursor += 1
                case 0xF2:
                    guard cursor + 2 <= trackEnd else { return nil }
                    cursor += 2
                default:
                    let dataBytes = Self.channelMessageLength(status)
                    guard cursor + dataBytes <= trackEnd else { return nil }
                    cursor += dataBytes
                }
            }
            trackEndTicks.append(tick)
            cursor = trackEnd
            remainingTracks -= 1
        }

        guard !trackEndTicks.isEmpty else { return nil }
        let lastTick = trackEndTicks.max()!

        tempoEvents.sort { $0.tick < $1.tick }
        if let first = tempoEvents.first, first.tick == 0 {
            // The file already defines the tempo at tick 0.
        } else {
            tempoEvents.insert((0, 500_000), at: 0)
        }

        var seconds: TimeInterval = 0
        var previousTick: Double = 0
        var currentMicroseconds: Double = tempoEvents.first!.microsecondsPerQuarter
        for event in tempoEvents where event.tick <= lastTick {
            seconds += Self.ticksToSeconds(event.tick - previousTick,
                                           ticksPerQuarter: ticksPerQuarter,
                                           microsecondsPerQuarter: currentMicroseconds,
                                           framesPerSecond: smpteFrameRate,
                                           ticksPerFrame: ticksPerFrame)
            previousTick = event.tick
            currentMicroseconds = event.microsecondsPerQuarter
        }
        seconds += Self.ticksToSeconds(lastTick - previousTick,
                                       ticksPerQuarter: ticksPerQuarter,
                                       microsecondsPerQuarter: currentMicroseconds,
                                       framesPerSecond: smpteFrameRate,
                                       ticksPerFrame: ticksPerFrame)
        self.duration = seconds
    }

    // MARK: - Reading primitives

    private static func ticksToSeconds(_ ticks: Double,
                                       ticksPerQuarter: Double,
                                       microsecondsPerQuarter: Double,
                                       framesPerSecond: Double,
                                       ticksPerFrame: Double) -> Double {
        if ticksPerQuarter > 0 {
            return ticks / ticksPerQuarter * microsecondsPerQuarter / 1_000_000
        }
        // SMPTE: every tick is 1 / (frameRate * ticksPerFrame) seconds.
        return ticks / (framesPerSecond * ticksPerFrame)
    }

    private static func channelMessageLength(_ status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 2
        case 0xC0, 0xD0: return 1
        default: return 0          // unreachable for valid channel statuses
        }
    }

    private static func readUInt32(_ data: Data, _ cursor: inout Int) -> UInt32? {
        guard cursor + 4 <= data.count else { return nil }
        let value = UInt32(data[cursor]) << 24
            | UInt32(data[cursor + 1]) << 16
            | UInt32(data[cursor + 2]) << 8
            | UInt32(data[cursor + 3])
        cursor += 4
        return value
    }

    private static func readUInt16(_ data: Data, _ cursor: inout Int) -> UInt16? {
        guard cursor + 2 <= data.count else { return nil }
        let value = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
        cursor += 2
        return value
    }

    /// A 24-bit big-endian value (used by the tempo meta event).
    private static func beat24(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[at]) << 16 | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2])
    }

    /// A MIDI variable-length quantity, which stops at a byte without the
    /// continuation bit.
    private static func readVarLen(_ data: Data, _ cursor: inout Int, limit: Int) -> UInt32? {
        var value: UInt32 = 0
        var bytesRead = 0
        while cursor < limit {
            let byte = data[cursor]
            cursor += 1
            bytesRead += 1
            value = value << 7 | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
            guard bytesRead < 5 else { return nil }    // a varlen is at most 4 bytes
        }
        return nil
    }
}
