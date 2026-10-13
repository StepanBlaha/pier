import ArgumentParser
import Foundation
import PierCore

struct App: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install / open the Pier menu bar app.",
        discussion: """
        `pier app install` assembles Pier.app (ad-hoc signed, no Apple Developer account needed) from the
        PierApp binary built next to this `pier`, and copies it to ~/Applications.
        """,
        subcommands: [AppInstall.self, AppOpen.self, AppUninstall.self, AppPath.self]
    )
}

private func installDir(_ to: String?) -> URL {
    guard let to else { return AppBundle.defaultInstallDir }
    return URL(fileURLWithPath: (to as NSString).expandingTildeInPath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
}

struct AppInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Build Pier.app into ~/Applications (or --to DIR).")

    @Option(name: .long, help: "Destination directory (default ~/Applications).") var to: String?
    @Flag(name: .customLong("no-open"), help: "Do not launch the app afterwards.") var noOpen = false
    @Flag(help: "Run `swift build -c release` first (default when run inside the pier repo without a PierApp binary).") var build = false

    func run() async throws {
        let dir = installDir(to)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repo = AppBundle.repoRoot(from: cwd)

        var binaries: AppBundle.Binaries?
        if build {
            guard let repo else { return fail("--build must run inside the pier repository (no Package.swift found above \(cwd.path))") }
            binaries = try buildRelease(in: repo)
        } else if let exe = AppBundle.currentExecutable(), let sib = AppBundle.siblingBinaries(of: exe) {
            binaries = sib
        } else if let repo {
            Term.err("PierApp binary not found next to pier; building release in \(repo.path)\(Term.glyphs.ellipsis)")
            binaries = try buildRelease(in: repo)
        }
        guard let binaries else {
            Term.fail("cannot find the PierApp binary next to `pier`. Build it first (`swift build -c release`) or run `pier app install --build` inside the pier repo.")
            throw ExitCode(1)
        }

        let templateRepo = repo ?? AppBundle.currentExecutable().flatMap { AppBundle.repoRoot(from: $0.deletingLastPathComponent()) }
        let template = AppBundle.templateFromRepo(templateRepo) ?? AppBundle.infoPlistTemplate
        var icon = AppBundle.iconFromRepo(templateRepo)
        if icon == nil {   // installing from an already-installed bundle: reuse its icon
            let sibling = binaries.cli.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
            if FileManager.default.fileExists(atPath: sibling.path) { icon = sibling }
        }

        let app: URL
        do {
            app = try AppBundle.install(binaries, options: .init(destinationDir: dir, template: template, icon: icon))
        } catch {
            Term.fail("\(error)")
            throw ExitCode(1)
        }
        print("Installed \(app.path)")
        if noOpen {
            print("Launch it with `pier app open`.")
        } else {
            do { try AppBundle.launch(app); print("Launched Pier.") } catch { Term.fail("\(error)") }
        }
        print("Note: enable launch at login in Pier > Settings.")
    }

    private func fail(_ msg: String) -> Void { Term.fail(msg) }

    private func buildRelease(in repo: URL) throws -> AppBundle.Binaries {
        Term.err("swift build -c release (this can take a few minutes)\(Term.glyphs.ellipsis)")
        for args in [["build", "-c", "release", "--product", "pier"], ["build", "-c", "release", "--product", "PierApp"]] {
            try runSwift(args, in: repo)
        }
        let binDir = try swiftOutput(["build", "-c", "release", "--show-bin-path"], in: repo)
        let bin = URL(fileURLWithPath: binDir)
        return .init(app: bin.appendingPathComponent("PierApp"), cli: bin.appendingPathComponent("pier"))
    }

    private func runSwift(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift"] + args
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            Term.fail("`swift \(args.joined(separator: " "))` failed")
            throw ExitCode(1)
        }
    }

    private func swiftOutput(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift"] + args
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AppOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Launch the installed Pier.app.")
    @Option(name: .long, help: "Directory containing Pier.app (default ~/Applications).") var to: String?

    func run() async throws {
        let app = AppBundle.appURL(in: installDir(to))
        guard FileManager.default.fileExists(atPath: app.path) else {
            Term.fail("Pier.app is not installed at \(app.path); run `pier app install`")
            throw ExitCode(1)
        }
        do { try AppBundle.launch(app) } catch { Term.fail("\(error)"); throw ExitCode(1) }
    }
}

struct AppUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Quit Pier and remove Pier.app. Managed processes keep running.")
    @Option(name: .long, help: "Directory containing Pier.app (default ~/Applications).") var to: String?

    func run() async throws {
        do {
            if let removed = try AppBundle.uninstall(from: installDir(to)) {
                print("Removed \(removed.path)")
            } else {
                print("Pier.app is not installed at \(AppBundle.appURL(in: installDir(to)).path)")
            }
        } catch { Term.fail("\(error)"); throw ExitCode(1) }
    }
}

struct AppPath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "path", abstract: "Print the installed Pier.app path (exit 1 if not installed).")
    @Option(name: .long, help: "Directory containing Pier.app (default ~/Applications).") var to: String?

    func run() async throws {
        let app = AppBundle.appURL(in: installDir(to))
        print(app.path)
        if !FileManager.default.fileExists(atPath: app.path) { throw ExitCode(1) }
    }
}
