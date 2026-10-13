import AppKit
import PierCore

/// Local key monitor active while the popover is key. Handles list navigation and row shortcuts so they work
/// regardless of whether the search field has focus.
@MainActor
final class KeyRouter {
    static let shared = KeyRouter()
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let result = self.handle(event) else { return event }
            return result ? nil : event
        }
    }

    /// nil = not ours (popover not key). true = consumed. false = pass through.
    private func handle(_ e: NSEvent) -> Bool? {
        let state = AppState.shared
        guard state.popoverVisible, let win = state.popoverWindow, e.window === win else { return nil }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = e.charactersIgnoringModifiers ?? ""
        let field = win.firstResponder as? NSTextView
        let fieldEmpty = (field?.string ?? "").isEmpty
        let caretAtEnd = field.map { $0.selectedRange.location >= ($0.string as NSString).length && $0.selectedRange.length == 0 } ?? true

        // Sheet-ish overlays swallow navigation; Esc dismisses them.
        if state.cleanup != nil {
            if e.keyCode == 53 { state.closeCleanup(); return true }
            return false
        }
        if state.qrService != nil {
            if e.keyCode == 53 { state.qrService = nil; return true }
            return false
        }
        if state.showWelcome {
            if e.keyCode == 53 || e.keyCode == 36 || e.keyCode == 76 { state.dismissWelcome(); return true }
            return false
        }
        if state.renaming { return false }

        switch (e.keyCode, mods) {
        case (53, []): // esc
            if state.detailID != nil { state.closeDetail() }
            else if !state.query.isEmpty { state.query = ""; state.ensureSelection() }
            else { state.closePopover() }
            return true
        case (126, []): // up
            if state.detailID == nil { state.move(-1); return true }
        case (125, []): // down
            if state.detailID == nil { state.move(1); return true }
        case (36, []), (76, []): // return
            if state.detailID == nil, state.selected != nil { state.activateSelection(); return true }
            if let s = state.detailService { state.open(s); return true }
        case (124, []): // right
            if state.detailID == nil, caretAtEnd {
                if state.expandSelection() { return true }
                if let s = state.selected { state.openDetail(s); return true }
            }
        case (123, []): // left
            if state.detailID != nil { state.closeDetail(); return true }
            if fieldEmpty, state.collapseSelection() { return true }
        case (51, [.command]): // cmd+delete
            if state.detailID == nil, let p = state.selectedProject { state.requestStop(p); return true }
            if let s = state.detailService ?? state.selected { state.requestKill(s); return true }
        case (43, [.command]): // cmd+,
            WindowManager.shared.showSettings(); return true
        default: break
        }
        if mods == [.command], chars == "c", fieldEmpty || (field?.selectedRange.length ?? 0) == 0 {
            if let s = state.detailService ?? state.selected { state.copyURL(s); return true }
        }
        return false
    }
}
