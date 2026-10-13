import ArgumentParser
import Foundation
import PierCore

struct Hello: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Meet the pier gull.",
        discussion: "Prints the mascot with a tip. Set PIER_NO_MASCOT=1 to hide every gull.")

    @Option(help: "Which pose: \(MascotPose.allCases.map(\.rawValue).joined(separator: ", ")).") var pose: String = "waving"
    @Flag(help: "List the available poses.") var list = false

    func validate() throws {
        guard MascotPose(rawValue: pose.lowercased()) != nil else {
            throw ValidationError("unknown pose \"\(Term.clean(pose))\"; try --list")
        }
    }

    func run() throws {
        if list {
            let w = MascotPose.allCases.map { $0.rawValue.count }.max() ?? 0
            for p in MascotPose.allCases {
                Term.out(p.rawValue.padding(toLength: w, withPad: " ", startingAt: 0) + "  " + (MascotHello.poseBlurbs[p] ?? ""))
            }
            return
        }
        let caps = Term.caps
        let env = ProcessInfo.processInfo.environment
        let p = MascotPose(rawValue: pose.lowercased()) ?? .waving
        let lines = MascotHello.lines(pose: p, version: Pier.configuration.version,
                                      tip: MascotHello.tips.randomElement() ?? "", caps: caps,
                                      showMascot: !Mascot.disabled(env: env))
        Term.out(lines.joined(separator: "\n"))
    }
}

/// Decorative gull for interactive runs. Everything it prints goes to stdout and only when stdout is an
/// interactive terminal (never piped / --json, never stderr); PIER_NO_MASCOT=1 turns it off.
enum MascotUI {
    /// Prints the gull beside `text` and returns true; returns false (printing nothing) when the caller
    /// should print its plain output instead.
    @discardableResult
    static func show(_ pose: MascotPose, size: MascotSize = .small, text: [String], blankBefore: Bool = false) -> Bool {
        guard let lines = Mascot.scene(pose, size, text: text, caps: Term.caps,
                                       env: ProcessInfo.processInfo.environment) else { return false }
        Term.out((blankBefore ? "\n" : "") + lines.joined(separator: "\n"))
        return true
    }

    static func hint(_ s: String) -> String { Term.paint(s, .dim) }
}

/// The saluting gull with a speech bubble above the root `pier help` (interactive terminals only, so piped
/// help stays plain text; PIER_NO_MASCOT=1 hides it).
enum HelpBanner {
    static func print() {
        let env = ProcessInfo.processInfo.environment
        let caps = Term.caps
        guard Mascot.enabled(caps: caps, env: env) else { return }
        let version = Pier.configuration.version
        let lines = MascotHello.greeting(pose: .saluting, text: MascotHello.helpBubbleText(version: version),
                                         caps: caps, showMascot: true)
        Term.out(lines.joined(separator: "\n") + "\n")
    }
}
