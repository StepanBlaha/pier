import ArgumentParser
import Foundation
import PierCore

/// Shared with the menu bar app: both read and write the same config.json (written atomically).
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show or change pier's settings (shared with the menu bar app).",
        discussion: """
        KEYS
        \(ConfigKey.allCases.map { "  \($0.rawValue.padding(toLength: 17, withPad: " ", startingAt: 0))\($0.summary)" }.joined(separator: "\n"))

          pier config                          list all keys (defaults marked)
          pier config set editor cursor
          pier config set hotkey opt+cmd+p
          pier config set notifyCrash off
          pier config unset editor             back to the default
          pier config edit                     open the file ($VISUAL / $EDITOR, else a text editor)
        """,
        subcommands: [List.self, Get.self, Set.self, Unset.self, Path.self, Edit.self],
        defaultSubcommand: List.self)

    static let keyCompletion: CompletionKind = .list(ConfigKey.allCases.map(\.rawValue))

    /// `config set <key> <TAB>`: values for the key typed just before the cursor.
    static let valueCompletion: CompletionKind = .custom { words, index, prefix in
        guard index >= 1, index <= words.count, let key = ConfigKey.parse(words[index - 1]) else { return [] }
        let p = prefix.lowercased()
        return key.completionValues.filter { p.isEmpty || $0.hasPrefix(p) }
    }

    struct Entry: Encodable {
        var key: String
        var value: ConfigValue
        var `default`: ConfigValue
        var isDefault: Bool
    }

    static func entry(_ key: ConfigKey, _ c: PierConfig) -> Entry {
        Entry(key: key.rawValue, value: ConfigEditing.jsonValue(key, in: c),
              default: ConfigEditing.jsonValue(key, in: PierConfig()), isDefault: ConfigEditing.isDefault(key, in: c))
    }

    static func key(_ text: String) throws -> ConfigKey {
        guard let k = ConfigKey.parse(text) else {
            Term.fail(ConfigError.unknownKey(Term.clean(text)).localizedDescription)
            throw ExitCode(64)
        }
        return k
    }

    /// Strict load for commands that write: refuses to overwrite a broken hand-edited file.
    static func loadForWrite() throws -> PierConfig {
        do { return try ConfigStore.loadStrict() } catch {
            Term.fail("\(error.localizedDescription)")
            throw ExitCode(1)
        }
    }

    static func save(_ c: PierConfig) throws {
        do { try ConfigStore.save(c) } catch {
            Term.fail("could not write \(ConfigStore.url.path): \(error.localizedDescription)")
            throw ExitCode(1)
        }
    }

    // MARK: list

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all settings (default).")
        @Flag(help: "Output JSON.") var json = false

        func run() throws {
            let c = ConfigStore.load()
            if json {
                Term.out(try Output.json(ConfigKey.allCases.map { ConfigCommand.entry($0, c) }))
                return
            }
            let width = (ConfigKey.allCases.map { $0.rawValue.count }.max() ?? 0) + 2
            let vals = ConfigKey.allCases.map { Term.clean(ConfigEditing.value($0, in: c)) }
            let vw = (vals.map { DisplayWidth.of($0) }.max() ?? 0) + 2
            for (k, v) in zip(ConfigKey.allCases, vals) {
                let isDef = ConfigEditing.isDefault(k, in: c)
                let head = Term.paint(DisplayWidth.pad(k.rawValue, to: width), .bold)
                Term.out(head + (isDef ? DisplayWidth.pad(v, to: vw) + Term.paint("(default)", .grey) : v))
            }
            if !c.pins.isEmpty || !c.renames.isEmpty {
                Term.out(Term.paint("\n\(c.pins.count) pinned, \(c.renames.count) renamed", .grey) + "  (pier pin / pier rename)")
            }
        }
    }

    // MARK: get

    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print one setting's value.")
        @Argument(help: "Setting name.", completion: ConfigCommand.keyCompletion) var key: String
        @Flag(help: "Output JSON.") var json = false

        func run() throws {
            let k = try ConfigCommand.key(key)
            let c = ConfigStore.load()
            if json { Term.out(try Output.json(ConfigCommand.entry(k, c))); return }
            Term.out(Term.clean(ConfigEditing.value(k, in: c)))
        }
    }

    // MARK: set

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a setting.",
            discussion: "Booleans accept true/false, on/off, yes/no. Hotkey needs a modifier: opt+cmd+p, ctrl+shift+space.")
        @Argument(help: "Setting name.", completion: ConfigCommand.keyCompletion) var key: String
        @Argument(help: "New value.", completion: ConfigCommand.valueCompletion) var value: String

        func run() throws {
            let k = try ConfigCommand.key(key)
            var c = try ConfigCommand.loadForWrite()
            do { try ConfigEditing.set(k, to: value, in: &c) } catch {
                Term.fail(Term.clean(error.localizedDescription))
                throw ExitCode(64)
            }
            try ConfigCommand.save(c)
            Term.out("\(k.rawValue) = \(Term.clean(ConfigEditing.value(k, in: c)))")
            if k == .launchAtLogin { Term.out("(takes effect through the menu bar app; the CLI only records the preference)") }
        }
    }

    // MARK: unset

    struct Unset: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Reset a setting to its default.")
        @Argument(help: "Setting name.", completion: ConfigCommand.keyCompletion) var key: String

        func run() throws {
            let k = try ConfigCommand.key(key)
            var c = try ConfigCommand.loadForWrite()
            ConfigEditing.unset(k, in: &c)
            try ConfigCommand.save(c)
            Term.out("\(k.rawValue) reset to \(Term.clean(ConfigEditing.value(k, in: c)))")
        }
    }

    // MARK: path

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the config file's location.")
        func run() { Term.out(ConfigStore.url.path) }
    }

    // MARK: edit

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open the config file in $VISUAL / $EDITOR (or the default text editor).")

        func run() throws {
            let url = ConfigStore.url
            if !FileManager.default.fileExists(atPath: url.path) {
                try ConfigCommand.save(PierConfig())   // something to edit
            }
            let env = ProcessInfo.processInfo.environment
            let editor = [env["VISUAL"], env["EDITOR"]].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let p = Process()
            if editor != nil, Term.canPrompt {
                // Terminal editors (vim, nano, ...) need our stdio; the shell splits "code -w" style values.
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "exec ${VISUAL:-$EDITOR} \"$0\"", url.path]
            } else {
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-t", url.path]
            }
            do { try p.run() } catch {
                Term.fail("could not start an editor: \(error.localizedDescription)")
                throw ExitCode(1)
            }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw ExitCode(p.terminationStatus) }
            if p.executableURL?.lastPathComponent == "open" {
                Term.out("Opened \(url.path)")
            } else if (try? ConfigStore.loadStrict()) == nil {
                Term.err("pier: warning: \(url.path) is not valid JSON now; pier falls back to defaults until it is fixed")
                throw ExitCode(1)
            }
        }
    }
}
