//
//  IcyTestServer.swift
//  APlayDemo
//
//  Runs a ShoutCast-style radio station on the device itself, so the inline
//  ICY metadata path can be exercised without depending on any external
//  server. The framework streams from it exactly as it would from a live
//  broadcast: `icy-metaint` switches the streamer into metadata mode and
//  every interval boundary carries a fresh `StreamTitle`.
//
//  Note on the status line: a genuine ShoutCast v1 server answers
//  `ICY 200 OK`, but CFNetwork parses that as a different protocol and strips
//  *every* header from the response — `icy-metaint` included, which silently
//  disables metadata mode. Answering `HTTP/1.1 200 OK` (as Icecast does) keeps
//  the headers, so that is what this server sends.
//

import Foundation
import Network
import SwiftUI

/// A local ShoutCast-style streamer that feeds `icy-metaint` framed MP3 to
/// whoever connects. Observable so the card can show the assigned port.
final class IcyTestServer: ObservableObject, @unchecked Sendable {

    @Published private(set) var port: UInt16 = 0
    @Published private(set) var isRunning = false
    @Published private(set) var clientCount = 0
    /// The title embedded in the most recently sent frame.
    @Published private(set) var lastTitle: String?
    @Published private(set) var startupError: String?

    /// Bytes of audio between two metadata frames.
    private static let metaint = 4096
    /// Pause between frames, roughly the rate 4096 bytes of 128 kbps audio is
    /// consumed at, so the demo plays continuously instead of buffering.
    private static let pace: TimeInterval = 0.25
    /// How many intervals each title is held for before rotating.
    private static let intervalsPerTitle = 4
    private static let bitrate = 128
    private static let stationName = "APlay demo radio"
    private static let genre = "Test"
    private static let streamURL = "https://github.com/CodeEagle/APlay"
    private static let titles = [
        "APlay demo · tone one",
        "APlay demo · tone two",
        "APlay demo · tone three",
        "APlay demo · tone four",
    ]

    /// All state below is touched only on `queue`.
    private let queue = DispatchQueue(label: "APlayDemo.IcyTestServer", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let media: Data
    private var mediaOffset = 0
    private var titleIndex = 0
    private var intervalCount = 0
    private var lastEmbeddedTitle: String?

    init() {
        // The bundled CBR MP3 is the payload — constant bitrate keeps the
        // audio data the metadata frames bracket byte-identical to the file.
        guard let url = Bundle.main.url(forResource: "tone-cbr", withExtension: "mp3"),
              let data = try? Data(contentsOf: url)
        else {
            media = Data()
            startupError = "tone-cbr.mp3 is missing from the app bundle"
            return
        }
        media = data
    }

    deinit {
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    // MARK: Lifecycle

    func start() {
        guard listener == nil, !media.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                let listener = try NWListener(using: .tcp, on: .any)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            self.publish { self.port = UInt16(port.rawValue) }
                        }
                        self.publish { self.isRunning = true }
                    case .failed:
                        self.stop()
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                self.publish { self.startupError = error.localizedDescription }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            for connection in self.connections { connection.cancel() }
            self.connections.removeAll()
            self.listener?.cancel()
            self.listener = nil
            self.mediaOffset = 0
            self.titleIndex = 0
            self.intervalCount = 0
            self.lastEmbeddedTitle = nil
            self.publish {
                self.isRunning = false
                self.port = 0
                self.clientCount = 0
                self.lastTitle = nil
            }
        }
    }

    /// The URL the player should stream from.
    func streamURL() -> URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/stream")
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.add(connection)
                self.sendHeader(to: connection)
            case .failed, .cancelled:
                self.remove(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func add(_ connection: NWConnection) {
        connections.append(connection)
        publish { self.clientCount = self.connections.count }
    }

    private func remove(_ connection: NWConnection) {
        if let index = connections.firstIndex(where: { $0 === connection }) {
            connections.remove(at: index)
        }
        connection.cancel()
        publish { self.clientCount = self.connections.count }
    }

    // MARK: Streaming

    /// The response header: no `Content-Length`, so the stream runs until the
    /// connection closes, exactly like a live broadcast.
    private func sendHeader(to connection: NWConnection) {
        let lines = [
            "HTTP/1.1 200 OK",
            "icy-name: \(Self.stationName)",
            "icy-genre: \(Self.genre)",
            "icy-br: \(Self.bitrate)",
            "icy-metaint: \(Self.metaint)",
            "",
        ]
        let header = lines.joined(separator: "\r\n") + "\r\n"
        connection.send(content: header.data(using: .utf8),
                         completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.sendChunk(to: connection)
            } else {
                self.remove(connection)
            }
        })
    }

    /// Sends one `metaint` of audio followed by its metadata frame, then
    /// schedules itself again — the loop a real server runs.
    private func sendChunk(to connection: NWConnection) {
        let title = nextTitle()
        var chunk = Data()
        chunk.append(nextAudioChunk())
        let frame = metadataFrame(title: title)
        // The length byte counts 16-byte blocks of the frame that follows.
        chunk.append(UInt8(frame.count / 16))
        chunk.append(frame)

        if lastEmbeddedTitle != title {
            lastEmbeddedTitle = title
            publish { self.lastTitle = title }
        }

        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                self.remove(connection)
                return
            }
            self.queue.asyncAfter(deadline: .now() + Self.pace) { [weak self] in
                guard let self else { return }
                self.sendChunk(to: connection)
            }
        })
    }

    /// `metaint` bytes of the payload, looping the source track when it ends.
    private func nextAudioChunk() -> Data {
        var audio = Data()
        var remaining = Self.metaint
        while remaining > 0 {
            let available = media.count - mediaOffset
            if available <= 0 {
                mediaOffset = 0
                continue
            }
            let take = min(remaining, available)
            audio.append(media.subdata(in: mediaOffset..<(mediaOffset + take)))
            mediaOffset += take
            remaining -= take
        }
        return audio
    }

    /// Rotates the title on a cadence so a metadata change is observable in
    /// the event log rather than repeating the same string forever.
    private func nextTitle() -> String {
        let title = Self.titles[titleIndex % Self.titles.count]
        intervalCount += 1
        if intervalCount.isMultiple(of: Self.intervalsPerTitle) {
            titleIndex += 1
        }
        return title
    }

    /// `StreamTitle='…';StreamUrl='…';` padded with spaces to a multiple of
    /// 16, as the ICY framing requires.
    private func metadataFrame(title: String) -> Data {
        var payload = "StreamTitle='\(title)';StreamUrl='\(Self.streamURL)';"
        while payload.count % 16 != 0 { payload += " " }
        return Data(payload.utf8)
    }

    // MARK: UI updates

    /// `@Published` mutations must land on the main thread; everything else in
    /// this class runs on its private serial queue.
    private func publish(_ block: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

// MARK: - Card

struct IcyStreamTestView: View {
    @ObservedObject var player: DemoPlayer
    @StateObject private var server = IcyTestServer()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("ICY inline metadata", symbol: "dot.radiowaves.left.and.right")

            Text("Runs a ShoutCast-style server on this device. The player "
                 + "connects over plain HTTP, `icy-metaint` turns on metadata "
                 + "mode, and every interval boundary delivers a fresh "
                 + "StreamTitle to the event pipeline.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))

            statusRow

            HStack(spacing: 10) {
                if server.isRunning {
                    Button {
                        server.stop()
                    } label: {
                        Label("Stop server", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.red.opacity(0.25), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Button {
                        if let url = server.streamURL() {
                            player.playRemote(url)
                        }
                    } label: {
                        Label("Stream it", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.black)
                    }
                } else {
                    Button {
                        server.start()
                    } label: {
                        Label("Start server", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.black)
                    }
                }
            }
            .font(.subheadline.weight(.semibold))

            if let error = server.startupError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(server.isRunning ? Color.green : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
            if server.isRunning, let url = server.streamURL() {
                Text(url.absoluteString)
                    .font(.caption2.weight(.medium).monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("stopped — port assigned on start")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if server.isRunning {
                Text("\(server.clientCount) client(s)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}
