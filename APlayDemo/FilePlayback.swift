//
//  FilePlayback.swift
//  APlayDemo
//
//  Plays any audio file the user picks from Files or iCloud Drive — the
//  bundled samples can only cover so many containers, so this hands the
//  engine a URL the app never shipped and lets the decoder chain report
//  what it could do with it.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document picker bridge

/// Wraps `UIDocumentPickerViewController` so SwiftUI can ask for an audio
/// file. The picker hands back security-scoped URLs, which `DemoPlayer`
/// keeps alive for as long as it plays them.
struct AudioDocumentPicker: UIViewControllerRepresentable {
    /// Receives the picked URL on the main thread.
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.audio],
                                                    asCopy: false)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Card

struct FilePlaybackView: View {
    @ObservedObject var player: DemoPlayer
    @State private var showPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Play a file from this device", symbol: "folder.fill")

            Text("Pick anything in Files or iCloud Drive: the picker hands the "
                 + "engine a security-scoped URL, and the same decoder chain "
                 + "that served the bundled samples serves it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))

            Button {
                showPicker = true
            } label: {
                Label("Choose an audio file", systemImage: "doc.fill.viewfinder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.black)
            }

            if case let .file(url) = player.source {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("sandbox scope held for as long as it plays")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Spacer()
                    Badge(text: "file")
                }
                .padding(10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .cardStyle()
        .sheet(isPresented: $showPicker) {
            AudioDocumentPicker { url in
                player.playFile(url)
            }
        }
    }
}
