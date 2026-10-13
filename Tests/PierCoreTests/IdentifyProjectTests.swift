import XCTest
@testable import PierCore

final class IdentifyProjectTests: IdentifyTestCase {
    // MARK: project root

    func testProjectRootWalksUpToPackageJson() throws {
        try write("web/package.json", "{}")
        let src = try mkdir("web/src/components")
        let root = tmp.appendingPathComponent("web").path
        let s = enriched(proc("node", cwd: src))
        XCTAssertEqual(s.projectPath, root)
        XCTAssertEqual(s.projectName, "web")
    }

    func testNearestMarkerWinsInMonorepo() throws {
        try mkdir("mono/.git")
        try write("mono/apps/admin/package.json", "{}")
        let cwd = try mkdir("mono/apps/admin/src")
        XCTAssertEqual(ProjectLocator.projectRoot(cwd: cwd), tmp.appendingPathComponent("mono/apps/admin").path)
    }

    func testAllMarkers() throws {
        for (i, marker) in ProjectLocator.markers.enumerated() {
            let dir = "m\(i)"
            if marker == ".git" { try mkdir("\(dir)/.git") } else { try write("\(dir)/\(marker)", "") }
            XCTAssertEqual(ProjectLocator.projectRoot(cwd: try mkdir("\(dir)/sub")), tmp.appendingPathComponent(dir).path, marker)
        }
    }

    func testNoProjectForRootNilOrMarkerless() throws {
        XCTAssertNil(ProjectLocator.projectRoot(cwd: "/"))
        XCTAssertNil(ProjectLocator.projectRoot(cwd: nil))
        XCTAssertNil(ProjectLocator.projectRoot(cwd: try mkdir("empty/dir")))
        let s = enriched(proc("launchd-thing", cwd: "/"))
        XCTAssertNil(s.projectPath)
    }

    func testStopsAtHome() throws {
        try write("home/package.json", "{}")
        let home = tmp.appendingPathComponent("home").path
        let cwd = try mkdir("home/docs")
        XCTAssertNil(ProjectLocator.projectRoot(cwd: cwd, home: home))
        XCTAssertNil(ProjectLocator.projectRoot(cwd: home, home: home))
    }

    func testToolchainPrefixesNeverProjects() {
        XCTAssertNil(ProjectLocator.projectRoot(cwd: "/opt/homebrew/var/postgresql@16"))
        XCTAssertNil(ProjectLocator.projectRoot(cwd: "/usr/local/var/postgres"))
    }

    // MARK: git

    func testGitBranchFromDirectory() throws {
        try write("repo/.git/HEAD", "ref: refs/heads/feature/login\n")
        try write("repo/package.json", "{}")
        let s = enriched(proc("node", cwd: try mkdir("repo/src")))
        XCTAssertEqual(s.gitBranch, "feature/login")
    }

    func testGitBranchDetachedHead() throws {
        try write("repo/.git/HEAD", "0123456789abcdef0123456789abcdef01234567\n")
        XCTAssertEqual(ProjectLocator.gitBranch(from: tmp.appendingPathComponent("repo").path), "0123456")
    }

    func testGitBranchFromWorktreeFile() throws {
        try write("main/.git/worktrees/wt/HEAD", "ref: refs/heads/hotfix\n")
        try write("wt/.git", "gitdir: \(tmp.path)/main/.git/worktrees/wt\n")
        try write("wt/package.json", "{}")
        let s = enriched(proc("node", cwd: tmp.appendingPathComponent("wt").path))
        XCTAssertEqual(s.gitBranch, "hotfix")
    }

    func testGitBranchRelativeGitdir() throws {
        try write("outer/.git/modules/sub/HEAD", "ref: refs/heads/dev\n")
        try write("outer/sub/.git", "gitdir: ../.git/modules/sub")
        XCTAssertEqual(ProjectLocator.gitBranch(from: tmp.appendingPathComponent("outer/sub").path), "dev")
    }

    func testGitBranchFoundAboveProject() throws {
        try write("mono/.git/HEAD", "ref: refs/heads/main")
        try write("mono/apps/web/package.json", "{}")
        let s = enriched(proc("node", cwd: tmp.appendingPathComponent("mono/apps/web").path))
        XCTAssertEqual(s.projectName, "web")
        XCTAssertEqual(s.gitBranch, "main")
    }

    // MARK: framework from argv

    private func fwID(_ args: [String], name: String = "node", cwd: String? = nil) -> String? {
        enriched(proc(name, args: args, cwd: cwd)).framework?.id
    }

    func testFrameworkFromArgv() {
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/next", "dev"]), "next")
        XCTAssertEqual(fwID(["next-server (v14.2.3)"], name: "next-server"), "next")
        XCTAssertEqual(fwID(["node", "/p/node_modules/vite/bin/vite.js"]), "vite")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/vitest"]), nil)
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/astro", "dev"]), "astro")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/nuxt", "dev"]), "nuxt")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/svelte-kit", "dev"]), "sveltekit")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/remix", "dev"]), "remix")
    }

    func testWebpackServeAndOthers() {
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/webpack", "serve", "--mode", "development"]), "webpack")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/parcel", "index.html"]), "parcel")
        XCTAssertEqual(fwID(["node", "/p/node_modules/@expo/cli/build/bin/cli", "start"]), "expo")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/storybook", "dev", "-p", "6006"]), "storybook")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/ng", "serve"]), "angular")
        XCTAssertEqual(fwID(["bun", "--hot", "server.ts"], name: "bun"), "bun")
        XCTAssertEqual(fwID(["deno", "run", "main.ts"], name: "deno"), "deno")
        XCTAssertEqual(fwID(["node", "/p/node_modules/.bin/wrangler", "dev"]), "wrangler")
    }

    func testBackendFrameworksFromArgv() {
        XCTAssertEqual(fwID(["ruby", "bin/rails", "server"], name: "ruby"), "rails")
        XCTAssertEqual(fwID(["puma 6.4.0 (tcp://localhost:3000) [app]"], name: "ruby"), "rails")
        XCTAssertEqual(fwID(["python", "manage.py", "runserver", "8000"], name: "python3"), "django")
        XCTAssertEqual(fwID(["python", "-m", "flask", "run"], name: "python3"), "flask")
        XCTAssertEqual(fwID(["/venv/bin/python", "/venv/bin/uvicorn", "app:app"], name: "python3"), "fastapi")
        XCTAssertEqual(fwID(["python3", "-m", "http.server", "8000"], name: "python3"), "python-http")
        XCTAssertEqual(fwID(["php", "artisan", "serve"], name: "php"), "laravel")
        XCTAssertEqual(fwID(["php", "-S", "localhost:8000"], name: "php"), "php")
        XCTAssertEqual(fwID(["jekyll", "serve"], name: "ruby"), "jekyll")
        XCTAssertEqual(fwID(["hugo", "server"], name: "hugo"), "hugo")
    }

    // MARK: framework from package.json

    func testFrameworkFromPackageJsonDependencies() throws {
        try write("a/package.json", #"{"dependencies":{"next":"14","react":"18"}}"#)
        try write("b/package.json", #"{"devDependencies":{"vite":"5"}}"#)
        try write("c/package.json", #"{"dependencies":{"express":"4"}}"#)
        try write("d/package.json", #"{"dependencies":{"@remix-run/node":"2"}}"#)
        try write("e/package.json", #"{"dependencies":{"left-pad":"1"}}"#)
        func fw(_ d: String) -> String? { enriched(proc("node", args: ["node", "server.js"], cwd: tmp.appendingPathComponent(d).path)).framework?.id }
        XCTAssertEqual(fw("a"), "next")
        XCTAssertEqual(fw("b"), "vite")
        XCTAssertEqual(fw("c"), "express")
        XCTAssertEqual(fw("d"), "remix")
        XCTAssertNil(fw("e"))
    }

    func testViteUpgradesToMetaFrameworkViaDeps() throws {
        try write("kit/package.json", #"{"devDependencies":{"@sveltejs/kit":"2","vite":"5"}}"#)
        let s = enriched(proc("node", args: ["node", "/x/node_modules/.bin/vite", "dev"], cwd: tmp.appendingPathComponent("kit").path))
        XCTAssertEqual(s.framework?.id, "sveltekit")
    }

    func testPackageJsonIgnoredForNonJSProcess() throws {
        try write("poly/package.json", #"{"dependencies":{"next":"14"}}"#)
        let s = enriched(proc("python3", args: ["python3", "worker.py"], cwd: tmp.appendingPathComponent("poly").path))
        XCTAssertNil(s.framework)
    }

    // MARK: refine

    func testRefineFromServerHeaderAndTitle() {
        var s = enriched(proc("python3", args: ["python3", "app.py"]), port: 5000)
        s.probe = ProbeResult(protocolKind: .http, health: .ok, httpStatus: 200, serverHeader: "Werkzeug/3.0 Python/3.12")
        Identifier.refine(&s)
        XCTAssertEqual(s.framework?.id, "flask")

        var v = enriched(proc("node", args: ["node", "x.js"]))
        v.probe = ProbeResult(protocolKind: .http, health: .ok, title: "Vite App")
        Identifier.refine(&v)
        XCTAssertEqual(v.framework?.id, "vite")

        var keep = enriched(proc("node", args: ["node", "/p/.bin/next", "dev"]))
        keep.probe = ProbeResult(protocolKind: .http, health: .ok, title: "Vite App")
        Identifier.refine(&keep)
        XCTAssertEqual(keep.framework?.id, "next")
    }

    func testRefineKeepsOtherForPlainHTTP() {
        var s = enriched(proc("mystery"))
        s.probe = ProbeResult(protocolKind: .http, health: .ok, title: "Hello")
        Identifier.refine(&s)
        XCTAssertEqual(s.kind, .other)
        XCTAssertNil(s.framework)
    }

    // MARK: runtime

    func testRuntimeVersionFromPaths() {
        func rt(_ name: String, _ exe: String) -> String? { enriched(proc(name, exe: exe, args: [name])).runtime }
        XCTAssertEqual(rt("node", "/Users/me/.nvm/versions/node/v20.11.1/bin/node"), "node 20.11.1")
        XCTAssertEqual(rt("node", "/opt/homebrew/Cellar/node/22.1.0/bin/node"), "node 22.1.0")
        XCTAssertEqual(rt("node", "/opt/homebrew/opt/node@20/bin/node"), "node 20")
        XCTAssertEqual(rt("node", "/Users/me/.volta/tools/image/node/20.11.1/bin/node"), "node 20.11.1")
        XCTAssertEqual(rt("node", "/opt/homebrew/bin/node"), "node")
        XCTAssertEqual(rt("python3.12", "/opt/homebrew/bin/python3.12"), "python 3.12")
        XCTAssertEqual(rt("python", "/Users/me/.pyenv/versions/3.12.2/bin/python"), "python 3.12.2")
        XCTAssertEqual(rt("ruby", "/Users/me/.rbenv/versions/3.3.0/bin/ruby"), "ruby 3.3.0")
        XCTAssertEqual(rt("bun", "/Users/me/.bun/bin/bun"), "bun")
        XCTAssertEqual(rt("java", "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java"), "java 21")
        XCTAssertNil(rt("postgres", "/opt/homebrew/opt/postgresql@16/bin/postgres"))
    }

    func testRuntimeIgnoresVersionedProjectFolderPrefix() {
        let s = enriched(proc("python", exe: "/Users/me/proj-1.2/venv/bin/python", args: ["python"]))
        XCTAssertEqual(s.runtime, "python")
    }
}
