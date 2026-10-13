import AppKit
import SwiftUI
import PierCore

/// Live log stream for one managed service.
@MainActor
final class LogsModel: ObservableObject {
    let manifest: ManagedManifest
    @Published var autoscroll = true
    @Published var status = "Connecting…"
    @Published var failed = false
    @Published var wrap = false

    /// Everything shown so far (for text views that attach late) and the live sink of the attached view.
    private(set) var buffer = ""
    var sink: ((String) -> Void)?
    private var task: Task<Void, Never>?
    private let maxLines = 10_000
    private var lineCount = 0

    init(manifest: ManagedManifest) { self.manifest = manifest }

    func start() {
        task?.cancel()
        failed = false
        status = "Live"
        task = Task { [manifest] in
            do {
                for try await chunk in ManagedClient.followLogs(manifest, tail: 1000) {
                    if Task.isCancelled { return }
                    append(chunk)
                }
                if !Task.isCancelled { status = "Stream ended (service stopped?)"; failed = true }
            } catch {
                if !Task.isCancelled { status = "\(error)"; failed = true }
            }
        }
    }

    func restartIfNeeded() { if failed { start() } }
    func stop() { task?.cancel(); task = nil }

    func clear() { buffer = ""; lineCount = 0; sink?("\u{0}clear") }

    private func append(_ raw: String) {
        let text = LogText.stripANSI(raw)
        guard !text.isEmpty else { return }
        buffer += text
        lineCount += text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if lineCount > maxLines + 500 {
            buffer = LogText.trimmed(buffer, maxLines: maxLines)
            lineCount = maxLines
            sink?("\u{0}reset")
        } else {
            sink?(text)
        }
    }
}

struct LogsView: View {
    @ObservedObject var model: LogsModel

    var body: some View {
        VStack(spacing: 0) {
            LogTextView(model: model)
            Divider()
            HStack(spacing: 12) {
                Circle().fill(model.failed ? Color.red : Color.green).frame(width: 7, height: 7)
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if model.failed { Button("Reconnect") { model.start() }.buttonStyle(.pier(.bordered)).font(.system(size: 11)).help("Reconnect to the log stream") }
                Toggle("Wrap", isOn: $model.wrap).toggleStyle(.checkbox).controlSize(.small)
                Toggle("Autoscroll", isOn: $model.autoscroll).toggleStyle(.checkbox).controlSize(.small)
                Button("Clear") { model.clear() }.buttonStyle(.pier(.bordered)).font(.system(size: 11)).help("Clear the log view")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .frame(minWidth: 420, minHeight: 240)
    }
}

private struct LogTextView: NSViewRepresentable {
    @ObservedObject var model: LogsModel

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = .labelColor
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.string = model.buffer
        context.coordinator.textView = tv
        applyWrap(tv, scroll: scroll)
        model.sink = { [weak coord = context.coordinator] chunk in coord?.receive(chunk) }
        context.coordinator.scrollToEnd()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        if let tv = scroll.documentView as? NSTextView { applyWrap(tv, scroll: scroll) }
        if model.autoscroll { context.coordinator.scrollToEnd() }
    }

    private func applyWrap(_ tv: NSTextView, scroll: NSScrollView) {
        let wrap = model.wrap
        scroll.hasHorizontalScroller = !wrap
        tv.isHorizontallyResizable = !wrap
        tv.textContainer?.widthTracksTextView = wrap
        tv.textContainer?.containerSize = NSSize(width: wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    @MainActor
    final class Coordinator {
        var model: LogsModel
        weak var textView: NSTextView?
        private var pending = ""
        private var scheduled = false
        init(model: LogsModel) { self.model = model }

        func receive(_ chunk: String) {
            guard let tv = textView else { return }
            if chunk == "\u{0}clear" { tv.string = ""; pending = ""; return }
            if chunk == "\u{0}reset" { pending = ""; tv.string = model.buffer; scrollIfNeeded(); return }
            pending += chunk
            // Coalesce bursts into ~10 UI updates per second.
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.flush() }
        }

        private func flush() {
            scheduled = false
            guard let tv = textView, !pending.isEmpty else { return }
            let attrs: [NSAttributedString.Key: Any] = [.font: tv.font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
                                                        .foregroundColor: NSColor.labelColor]
            tv.textStorage?.append(NSAttributedString(string: pending, attributes: attrs))
            pending = ""
            scrollIfNeeded()
        }

        private func scrollIfNeeded() { if model.autoscroll { scrollToEnd() } }
        func scrollToEnd() { textView?.scrollToEndOfDocument(nil) }
    }
}
