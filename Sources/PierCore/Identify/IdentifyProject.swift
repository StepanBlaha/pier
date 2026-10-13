import Foundation

/// Project root + git branch discovery. Pure filesystem reads, never spawns processes.
enum ProjectLocator {
    static let markers = ["package.json", ".git", "pyproject.toml", "requirements.txt", "Gemfile", "go.mod",
                          "Cargo.toml", "composer.json", "deno.json", "deno.jsonc", "bun.lockb", "mix.exs"]

    /// Nearest ancestor of `cwd` (inclusive) containing a project marker. Ignores nil, "/" and $HOME.
    static func projectRoot(cwd: String?, home: String = DirWalk.defaultHome) -> String? {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return nil }
        let fm = FileManager.default
        return DirWalk.findUp(from: cwd, home: home) { dir in
            markers.contains { fm.fileExists(atPath: dir + "/" + $0) }
        }
    }

    /// Current branch (or short sha when detached) for the repo containing `path`.
    /// Handles worktrees/submodules where `.git` is a file ("gitdir: …").
    static func gitBranch(from path: String, home: String = DirWalk.defaultHome) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard let repo = DirWalk.findUp(from: path, home: home, where: { fm.fileExists(atPath: $0 + "/.git") }) else { return nil }
        let dotGit = repo + "/.git"
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }

        var gitDir = dotGit
        if !isDir.boolValue {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = target.hasPrefix("/") ? target : repo + "/" + target
        }
        guard let head = try? String(contentsOfFile: gitDir + "/HEAD", encoding: .utf8) else { return nil }
        return parseHead(head)
    }

    static func parseHead(_ raw: String) -> String? {
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            for prefix in ["refs/heads/", "refs/"] where ref.hasPrefix(prefix) { return String(ref.dropFirst(prefix.count)) }
            return ref.isEmpty ? nil : ref
        }
        let isSha = head.count >= 7 && head.allSatisfy(\.isHexDigit)
        return isSha ? String(head.prefix(7)) : nil
    }

    /// dependencies + devDependencies keys of `<dir>/package.json`.
    static func packageDependencies(at dir: String) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: dir + "/package.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var deps = Set<String>()
        for key in ["dependencies", "devDependencies"] {
            if let d = json[key] as? [String: Any] { deps.formUnion(d.keys) }
        }
        return deps
    }
}

// MARK: - Framework detection

struct FrameworkRule {
    let framework: Framework
    /// Matches when any argv/name token (basename, script extension stripped) equals one of these.
    var words: [String] = []
    /// Matches when the space-joined, lowercased argv contains one of these.
    var phrases: [String] = []
}

enum FrameworkDetector {
    private static func fw(_ id: String, _ name: String, words: [String] = [], phrases: [String] = []) -> FrameworkRule {
        FrameworkRule(framework: Framework(id: id, name: name), words: words, phrases: phrases)
    }

    /// Ordered: meta-frameworks before their bundlers, runtimes last. First match wins.
    static let argvRules: [FrameworkRule] = [
        fw("next", "Next.js", words: ["next", "next-server", "next-router-worker", "next-render-worker"]),
        fw("nuxt", "Nuxt", words: ["nuxt", "nuxi", "nuxt-ts"], phrases: ["/nuxt/", "@nuxt/"]),
        fw("sveltekit", "SvelteKit", words: ["svelte-kit"], phrases: ["@sveltejs/kit"]),
        fw("remix", "Remix", words: ["remix", "remix-serve"], phrases: ["@remix-run/"]),
        fw("astro", "Astro", words: ["astro"]),
        fw("gatsby", "Gatsby", words: ["gatsby"]),
        fw("docusaurus", "Docusaurus", words: ["docusaurus"]),
        fw("vitepress", "VitePress", words: ["vitepress"]),
        fw("eleventy", "Eleventy", words: ["eleventy"], phrases: ["@11ty/"]),
        fw("angular", "Angular", words: ["ng"]),
        fw("cra", "Create React App", words: ["react-scripts"]),
        fw("expo", "Expo", words: ["expo", "expo-cli", "metro"], phrases: ["expo start", "expo/bin/cli", "@expo/cli"]),
        fw("storybook", "Storybook", words: ["storybook", "start-storybook"], phrases: ["/storybook/", "@storybook/", "storybook dev"]),
        fw("webpack", "webpack", words: ["webpack-dev-server"], phrases: ["webpack serve"]),
        fw("parcel", "Parcel", words: ["parcel"]),
        fw("vite", "Vite", words: ["vite"]),
        fw("rails", "Rails", words: ["rails", "puma"], phrases: ["rails server"]),
        fw("django", "Django", phrases: ["manage.py runserver", "django-admin runserver", "runserver"]),
        fw("flask", "Flask", words: ["flask"], phrases: ["-m flask"]),
        fw("fastapi", "FastAPI", words: ["uvicorn", "fastapi"]),
        fw("streamlit", "Streamlit", words: ["streamlit"]),
        fw("jupyter", "Jupyter", words: ["jupyter", "jupyter-lab", "jupyter-notebook", "jupyter-server"]),
        fw("jekyll", "Jekyll", words: ["jekyll"]),
        fw("hugo", "Hugo", words: ["hugo"]),
        fw("python-http", "Python http.server", phrases: ["http.server"]),
        fw("laravel", "Laravel", words: ["artisan"], phrases: ["artisan serve", "illuminate/foundation/resources/server.php"]),
        fw("php", "PHP", phrases: ["php -s "]),
        fw("phoenix", "Phoenix", phrases: ["phx.server"]),
        fw("wrangler", "Wrangler", words: ["wrangler", "workerd"]),
        fw("bun", "Bun", phrases: ["bun --hot", "bun --watch"]),
        fw("deno", "Deno", words: ["deno"]),
    ]

    /// package.json dependency → framework, in priority order. `prefix` rules match `dep.hasPrefix`.
    struct DepRule { let dep: String; var prefix = false; let framework: Framework }
    private static func dep(_ d: String, _ id: String, _ name: String, prefix: Bool = false) -> DepRule {
        DepRule(dep: d, prefix: prefix, framework: Framework(id: id, name: name))
    }
    static let depRules: [DepRule] = [
        dep("next", "next", "Next.js"),
        dep("nuxt", "nuxt", "Nuxt"),
        dep("@sveltejs/kit", "sveltekit", "SvelteKit"),
        dep("astro", "astro", "Astro"),
        dep("@remix-run/", "remix", "Remix", prefix: true),
        dep("gatsby", "gatsby", "Gatsby"),
        dep("@angular/core", "angular", "Angular"),
        dep("react-scripts", "cra", "Create React App"),
        dep("@docusaurus/core", "docusaurus", "Docusaurus"),
        dep("vitepress", "vitepress", "VitePress"),
        dep("vite", "vite", "Vite"),
        dep("@nestjs/core", "nestjs", "NestJS"),
        dep("fastify", "fastify", "Fastify"),
        dep("express", "express", "Express"),
    ]

    /// When argv says plain Vite but package.json reveals a meta-framework built on it.
    static let viteHosts: Set<String> = ["sveltekit", "remix", "nuxt", "astro"]

    static let scriptExtensions: Set<String> = ["js", "mjs", "cjs", "ts", "mts", "py", "rb", "php"]

    static func tokens(_ f: ProcFacets) -> Set<String> {
        var out = Set<String>()
        for raw in [f.name] + f.args {
            for piece in raw.split(whereSeparator: \.isWhitespace) {
                var base = (String(piece) as NSString).lastPathComponent
                let ext = (base as NSString).pathExtension
                if scriptExtensions.contains(ext) { base = (base as NSString).deletingPathExtension }
                out.insert(base)
            }
        }
        return out
    }

    static func fromArgv(_ f: ProcFacets) -> Framework? {
        let toks = tokens(f)
        let hay = f.haystack
        return argvRules.first { r in
            r.words.contains(where: toks.contains) || r.phrases.contains(where: hay.contains)
        }?.framework
    }

    static func fromDependencies(_ deps: Set<String>) -> Framework? {
        depRules.first { r in r.prefix ? deps.contains { $0.hasPrefix(r.dep) } : deps.contains(r.dep) }?.framework
    }

    static func detect(_ f: ProcFacets, projectPath: String?, isJS: Bool) -> Framework? {
        var found = fromArgv(f)
        guard let projectPath else { return found }
        let needsDeps = found?.id == "vite" || (found == nil && isJS)
        guard needsDeps else { return found }
        let fromDeps = fromDependencies(ProjectLocator.packageDependencies(at: projectPath))
        if found?.id == "vite" {
            if let d = fromDeps, viteHosts.contains(d.id) { found = d }
        } else {
            found = fromDeps
        }
        return found
    }
}
