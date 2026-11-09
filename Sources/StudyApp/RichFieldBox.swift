import AppKit
import AVFoundation
import Observation
import SwiftUI

/// One field in Add Cards: a formatting bar over an editor that shows the
/// field as it will look on the card.
struct RichFieldBox: View {
    @Binding var html: String
    @Binding var height: CGFloat
    let handle: RichEditorHandle
    var minHeight: CGFloat = 60
    @Binding var pinned: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var recording = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.6)
            RichFieldEditor(html: html, dark: colorScheme == .dark, handle: handle, height: $height) { html = $0 }
                .frame(height: max(minHeight, height))
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(pinned ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(.separator)))
    }

    private var toolbar: some View {
        HStack(spacing: 1) {
            tool("bold", "Bold (⌘B)") { handle.format("bold") }
            tool("italic", "Italic") { handle.format("italic") }
            tool("underline", "Underline (⌘U)") { handle.format("underline") }
            tool("textformat.superscript", "Superscript, e.g. Ca²⁺") { handle.format("superscript") }
            tool("textformat.subscript", "Subscript, e.g. H₂O") { handle.format("subscript") }
            Menu {
                ForEach(Self.colours, id: \.name) { colour in
                    Button {
                        handle.format("foreColor", colour.hex)
                    } label: {
                        Label(colour.name, systemImage: "circle.fill")
                    }
                }
                Divider()
                Button("Highlight") { handle.format("hiliteColor", "#fff3a3") }
            } label: {
                Image(systemName: "paintpalette").frame(width: 24, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(.hoverable)
            .menuIndicator(.hidden)
            .fixedSize()
            .tip("Text colour or highlight")
            tool("list.bullet", "Bullet list") { handle.format("insertUnorderedList") }
            tool("list.number", "Numbered list") { handle.format("insertOrderedList") }
            tool("eraser", "Clear formatting") { handle.format("removeFormat") }

            Divider().frame(height: 14).padding(.horizontal, 4)

            tool("photo.badge.plus", "Add a picture, sound or video (or paste / drag one in)") { attach() }
            AudioRecordButton(recording: $recording) { name in
                handle.insertHTML(MediaFiles.html(for: name))
            }

            Spacer(minLength: 4)
            Button {
                pinned.toggle()
            } label: {
                Label(pinned ? "Kept" : "Keep", systemImage: pinned ? "pin.fill" : "pin")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 5)
                    .frame(height: 22)
            }
            .buttonStyle(.hoverable)
            .tip(pinned ? "This field keeps its text after you add a card. Click to stop."
                         : "Keep this field's text for the next card (handy for a source or topic)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.03))
    }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22)
        }
        .buttonStyle(.hoverable)
        .tip(help)
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaFiles.pickableTypes
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures, sounds or videos to put on the card"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let name = try? MediaFiles.add(fileAt: url) {
                handle.insertHTML(MediaFiles.html(for: name))
            }
        }
    }

    private static let colours: [(name: String, hex: String)] = [
        ("Red", "#d93a32"), ("Orange", "#e07b12"), ("Green", "#2e9b47"),
        ("Blue", "#2f6fdc"), ("Purple", "#8a4fd8"), ("Grey", "#808080"),
    ]
}

/// Records your voice into the media folder (e.g. how to pronounce a drug name).
private struct AudioRecordButton: View {
    @Binding var recording: Bool
    let onSaved: (String) -> Void
    @State private var recorder = VoiceRecorder()

    var body: some View {
        Button {
            Task { await toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "mic")
                    .foregroundStyle(recorder.isRecording ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                if recorder.isRecording {
                    Text(SimpleTimer.clock(recorder.seconds)).font(.caption.monospacedDigit()).foregroundStyle(.red)
                }
            }
            .frame(minWidth: 24, minHeight: 22)
        }
        .buttonStyle(.hoverable)
        .tip(recorder.isRecording ? "Stop and add the recording" : "Record audio")
        .popover(isPresented: Binding(get: { recorder.problem != nil }, set: { if !$0 { recorder.problem = nil } })) {
            Text(recorder.problem ?? "").padding(14).frame(width: 260)
        }
    }

    private func toggle() async {
        if recorder.isRecording {
            if let name = recorder.stop() { onSaved(name) }
        } else {
            await recorder.start()
        }
        recording = recorder.isRecording
    }
}

@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var seconds = 0
    var problem: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var name: String?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    func start() async {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else {
            problem = "Animus isn't allowed to use the microphone. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let fileName = "rec-\(stamp).m4a"
        let url = Library.mediaFolder.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            name = fileName
            isRecording = true
            seconds = 0
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.seconds += 1
                }
            }
        } catch {
            problem = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    /// Stops and returns the saved file's name (nil if it was too short to keep).
    func stop() -> String? {
        ticker?.cancel()
        let length = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        isRecording = false
        guard let name else { return nil }
        self.name = nil
        if length < 0.3 {
            try? FileManager.default.removeItem(at: Library.mediaFolder.appendingPathComponent(name))
            return nil
        }
        return name
    }
}

