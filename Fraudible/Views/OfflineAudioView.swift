import SwiftUI

/// Make a book's read-aloud audio ahead of time, so it plays instantly and works offline.
struct OfflineAudioSheet: View {
    let book: LibraryBook
    /// The voice the reader is using; offered first when it's a Kokoro voice.
    let currentVoice: ReaderVoice
    @Environment(OfflineAudioMaker.self) private var maker
    @Environment(KokoroManager.self) private var kokoro
    @Environment(\.dismiss) private var dismiss
    @State private var voice: ReaderVoice
    @State private var size: Int64 = 0
    @State private var confirmDelete = false
    @State private var confirmReplace = false

    init(book: LibraryBook, currentVoice: ReaderVoice) {
        self.book = book
        self.currentVoice = currentVoice
        let fallback = VoiceCatalog.kokoro.first { $0.engineVoiceID == (VoiceCatalog.prefersBritish ? "bf_emma" : "af_heart") }!
        _voice = State(initialValue: currentVoice.engine == .kokoro ? currentVoice : fallback)
    }

    private var job: OfflineAudioMaker.Job? { maker.job(book.id) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        Text("Turn this book into audio on your iPhone, like a downloaded audiobook. It then plays instantly, works offline and uses less battery while you listen. Highlighting and pausing on a word still work.")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }

                if let job {
                    progressSection(job)
                } else {
                    setupSection
                }
            }
            .navigationTitle("Offline Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this book’s offline audio?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete \(Self.bytes(size))", role: .destructive) { maker.delete(book.id) }
            } message: {
                Text("Reading aloud will make the audio live again.")
            }
            .confirmationDialog("Start again with \(voice.name)?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Replace Audio", role: .destructive) { maker.start(book.id, voice: voice) }
            } message: {
                Text("The audio made so far with \(job?.voice.name ?? "the other voice") will be deleted.")
            }
        }
        // Re-measure now and then (it means listing every file), not after every sentence.
        .task(id: "\((job?.done ?? 0) / 50)-\(job?.state == .complete)") {
            let id = book.id
            size = await Task.detached(priority: .utility) { OfflineAudioStore.size(id) }.value
        }
    }

    // MARK: - Before starting

    @ViewBuilder private var setupSection: some View {
        Section("Voice") {
            voicePicker
        }
        Section {
            LabeledContent("Length", value: "about \(Self.duration(estimatedSeconds))")
            LabeledContent("Space needed", value: "about \(Self.bytes(Int64(estimatedSeconds * OfflineAudioStore.bytesPerSecond)))")
        } footer: {
            Text("Fraudible needs to stay open while it works; it keeps the screen on, so leaving your iPhone on charge is a good idea. If you leave the app it carries on when you come back.")
        }
        Section {
            if kokoro.isDownloaded {
                Button {
                    maker.start(book.id, voice: voice)
                } label: {
                    Label("Make Offline Audio", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .listRowBackground(Color.clear)
            } else if kokoro.status == .downloading {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Downloading the Kokoro voice… \(Int(kokoro.progress * 100))%").font(.subheadline)
                    ProgressView(value: kokoro.progress)
                }
            } else {
                Button {
                    kokoro.download()
                } label: {
                    Label("Download Kokoro First (\(KokoroManager.downloadSize))", systemImage: "icloud.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .listRowBackground(Color.clear)
            }
        } footer: {
            if !kokoro.isDownloaded {
                Text("Offline audio is made with Kokoro, the natural voice that runs on your iPhone. Apple’s voices already work offline.")
            }
        }
    }

    private var voicePicker: some View {
        Picker("Voice", selection: $voice) {
            ForEach(VoiceCatalog.kokoro) { v in
                Text("\(v.name) · \(v.accent) \(v.detail)").tag(v)
            }
        }
    }

    /// From the book's length: Kokoro speaks about 13 characters a second.
    private var estimatedSeconds: Double {
        guard let name = book.textFileName else { return 0 }
        let bytes = (try? Storage.fileURL(bookId: book.id, name: name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Double(bytes) / OfflineAudioStore.charsPerSecond
    }

    // MARK: - Making / made

    @ViewBuilder private func progressSection(_ job: OfflineAudioMaker.Job) -> some View {
        Section {
            LabeledContent("Voice", value: "\(job.voice.name) · \(job.voice.accent)")
            switch job.state {
            case .complete:
                Label("Ready to play offline", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Space used", value: Self.bytes(size))
            default:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(stateTitle(job.state)).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(Int(job.fraction * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: job.fraction)
                    Text(detail(job))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                if case .failed(let message) = job.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        } footer: {
            if job.state == .running {
                Text("Keep Fraudible open: the screen stays on while it works. Listening now uses the audio that’s ready and makes the rest live.")
            }
        }

        Section {
            switch job.state {
            case .running, .queued:
                Button("Pause") { maker.pause(book.id) }
            case .paused, .failed:
                Button("Resume") { maker.start(book.id, voice: job.voice) }
            case .complete:
                EmptyView()
            }
            if job.state != .running {
                DisclosureGroup("Use a Different Voice") {
                    voicePicker
                    Button("Make Audio with \(voice.name)") { confirmReplace = true }
                        .disabled(voice == job.voice || !kokoro.isDownloaded)
                }
            }
            Button("Delete Offline Audio", role: .destructive) { confirmDelete = true }
        }
    }

    private func stateTitle(_ state: OfflineAudioMaker.State) -> String {
        switch state {
        case .running: "Making audio…"
        case .queued: "Waiting for another book to finish"
        case .paused: "Paused"
        case .failed: "Stopped"
        case .complete: "Ready"
        }
    }

    private func detail(_ job: OfflineAudioMaker.Job) -> String {
        var parts = ["\(job.done.formatted()) of \(job.total.formatted()) sentences"]
        if job.state == .running, let left = job.timeLeft, job.done > 3 {
            parts.append("about \(Self.duration(left)) left")
        }
        if size > 0 { parts.append(Self.bytes(size)) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

/// The toolbar button for offline audio: shows progress while audio is being made.
struct OfflineAudioButton: View {
    let bookID: String
    let action: () -> Void
    @Environment(OfflineAudioMaker.self) private var maker

    var body: some View {
        Button(action: action) {
            switch maker.job(bookID)?.state {
            case .complete?:
                Label("Offline Audio", systemImage: "checkmark.circle")
            case .running?, .queued?:
                ProgressRing(value: maker.job(bookID)?.fraction ?? 0, size: 20)
                    .accessibilityLabel("Making offline audio")
            default:
                Label("Make Offline Audio", systemImage: "arrow.down.circle")
            }
        }
    }
}
