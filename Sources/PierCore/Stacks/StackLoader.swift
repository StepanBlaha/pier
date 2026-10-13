import Foundation
import Yams

public enum StackLoader {
    /// Accepted file names, in lookup order.
    public static let fileNames = ["pier.yml", "pier.yaml", ".pier.yml", ".pier.yaml"]

    /// Walks up from `start` (inclusive) looking for a stack file; stops after `$HOME` (so a stray file in `/` is never picked up).
    public static func find(from start: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        var dir = start.standardizedFileURL.resolvingSymlinksInPath()
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        while true {
            if let f = file(in: dir) { return f }
            if dir.path == homePath || dir.path == "/" { return nil }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
    }

    /// First stack file inside `dir`, if any.
    public static func file(in dir: URL) -> URL? {
        for n in fileNames {
            let u = dir.appendingPathComponent(n)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { return u }
        }
        return nil
    }

    /// Loads and validates a stack file. `url` may also be a directory containing one.
    public static func load(url: URL) throws -> StackFile {
        var target = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) else {
            throw StackError.notFound("no such file: \(url.path)")
        }
        if isDir.boolValue {
            guard let f = file(in: target) else { throw StackError.notFound("no pier.yml in \(url.path)") }
            target = f
        }
        guard let data = try? Data(contentsOf: target), let text = String(data: data, encoding: .utf8) else {
            throw StackError.unreadable("cannot read \(target.path)")
        }
        return try parse(yaml: text, url: target)
    }

    /// Parses + validates YAML text. `url` determines the default stack name and the base for relative `cwd`s.
    public static func parse(yaml: String, url: URL) throws -> StackFile {
        let url = url.standardizedFileURL
        let fileLabel = url.lastPathComponent
        var v = Validator(file: fileLabel, dir: url.deletingLastPathComponent())

        let root: Node?
        do { root = try Yams.compose(yaml: yaml) }
        catch { throw StackError.syntax("\(fileLabel): \(Self.describe(error))") }
        guard let root, let top = root.mapping else {
            throw StackError.invalid([StackIssue(file: fileLabel, line: root?.mark?.line, keyPath: "", message: "top level must be a mapping with a `services:` key")])
        }

        var name: String?
        var servicesNode: Node?
        for (k, val) in top {
            guard let key = k.scalar?.string else { v.issue(k, "", "keys must be strings"); continue }
            switch key {
            case "name":
                if let s = val.scalar?.string, !s.isEmpty { name = s } else { v.issue(val, "name", "must be a non-empty string") }
            case "services": servicesNode = val
            default: v.warn(k, "unknown key '\(key)' (ignored)")
            }
        }
        if let n = name, !Validator.validName(n) {
            v.issue(top["name"] ?? root, "name", "'\(n)' may only contain letters, digits, '.', '_' and '-'")
        }
        let stackName = name ?? Validator.sanitize(url.deletingLastPathComponent().lastPathComponent)

        var services: [StackService] = []
        if let sn = servicesNode {
            if let m = sn.mapping {
                var seen = Set<String>()
                for (k, val) in m {
                    guard let svcName = k.scalar?.string else { v.issue(k, "services", "service names must be strings"); continue }
                    if !Validator.validName(svcName) {
                        v.issue(k, "services.\(svcName)", "invalid service name (use letters, digits, '.', '_', '-')"); continue
                    }
                    if !seen.insert(svcName).inserted { v.issue(k, "services.\(svcName)", "duplicate service name"); continue }
                    if let s = v.service(name: svcName, key: k, node: val) { services.append(s) }
                }
            } else {
                v.issue(sn, "services", "must be a mapping of service name -> definition")
            }
        } else {
            v.issue(root, "", "missing required `services:` key")
        }
        if servicesNode != nil, services.isEmpty, v.issues.isEmpty {
            v.issue(servicesNode!, "services", "no services defined")
        }

        v.crossChecks(services)
        if !v.issues.isEmpty { throw StackError.invalid(v.issues) }
        return StackFile(name: stackName, path: url.path, services: services, warnings: v.warnings)
    }

    static func describe(_ error: Error) -> String {
        let s = "\(error)"
        return s.split(separator: "\n").prefix(3).joined(separator: " ")
    }
}

// MARK: - validation

private struct Validator {
    let file: String
    let dir: URL
    var issues: [StackIssue] = []
    var warnings: [String] = []
    /// service name -> line of its key, for cross-check messages
    var lines: [String: Int] = [:]
    var depLines: [String: Int] = [:]
    var portLines: [String: Int] = [:]

    init(file: String, dir: URL) { self.file = file; self.dir = dir }

    private static func validChar(_ c: Character) -> Bool {
        (c.isASCII && (c.isLetter || c.isNumber)) || c == "." || c == "_" || c == "-"
    }
    static func validName(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(validChar) }
    static func sanitize(_ s: String) -> String {
        let out = String(s.map { validChar($0) ? $0 : "-" })
        return out.isEmpty ? "stack" : out
    }

    mutating func issue(_ node: Node, _ path: String, _ msg: String) {
        issues.append(StackIssue(file: file, line: node.mark?.line, keyPath: path, message: msg))
    }
    mutating func warn(_ node: Node, _ msg: String) {
        let loc = node.mark.map { "\(file):\($0.line)" } ?? file
        warnings.append("\(loc): \(msg)")
    }

    mutating func service(name: String, key: Node, node: Node) -> StackService? {
        let base = "services.\(name)"
        guard let m = node.mapping else {
            issue(node, base, "must be a mapping (with at least `run:`)"); return nil
        }
        lines[name] = key.mark?.line
        let before = issues.count

        var command: [String] = []
        var display = ""
        var sawRun = false
        var cwdRaw: String?
        var port: UInt16?
        var env: [String: String] = [:]
        var deps: [String] = []
        var ready: StackReadyCheck?
        var readyTimeout: TimeInterval = 60

        for (k, val) in m {
            guard let key = k.scalar?.string else { issue(k, base, "keys must be strings"); continue }
            let path = "\(base).\(key)"
            switch key {
            case "run":
                sawRun = true
                if let s = val.scalar?.string, val.sequence == nil {
                    display = s
                    do {
                        command = try StackShell.command(for: s)
                        if command.isEmpty { issue(val, path, "run is empty") }
                    } catch { issue(val, path, "\(error) in command: \(s)") }
                } else if let seq = val.sequence {
                    var argv: [String] = []
                    for (i, item) in seq.enumerated() {
                        if let s = item.scalar?.string { argv.append(s) } else { issue(item, "\(path)[\(i)]", "array items must be strings") }
                    }
                    if argv.isEmpty { issue(val, path, "run array is empty") }
                    command = argv; display = argv.joined(separator: " ")
                } else { issue(val, path, "must be a string or an array of strings") }
            case "cwd":
                if let s = val.scalar?.string, !s.isEmpty { cwdRaw = s } else { issue(val, path, "must be a non-empty string") }
            case "port":
                if let p = val.int, (1...65535).contains(p) { port = UInt16(p); portLines[name] = val.mark?.line }
                else { issue(val, path, "invalid port '\(val.scalar?.string ?? "?")' (expected an integer 1-65535)") }
            case "env":
                if let em = val.mapping {
                    for (ek, ev) in em {
                        guard let en = ek.scalar?.string else { issue(ek, path, "env keys must be strings"); continue }
                        guard let sv = ev.scalar else { issue(ev, "\(path).\(en)", "env values must be scalars"); continue }
                        env[en] = ev.null != nil ? "" : sv.string
                    }
                } else if val.null == nil { issue(val, path, "must be a mapping of NAME: value") }
            case "depends_on":
                depLines[name] = val.mark?.line
                if let seq = val.sequence {
                    for (i, item) in seq.enumerated() {
                        if let s = item.scalar?.string { deps.append(s) } else { issue(item, "\(path)[\(i)]", "must be a service name") }
                    }
                } else if let s = val.scalar?.string, val.null == nil { deps = [s] }
                else if val.null == nil { issue(val, path, "must be a list of service names") }
            case "ready":
                guard let s = val.scalar?.string else { issue(val, path, "must be http, port, none or log:<regex>"); break }
                switch s {
                case "http": ready = .http
                case "port": ready = .port
                case "none", "false": ready = StackReadyCheck.none
                default:
                    if s.hasPrefix("log:") {
                        let pattern = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                        if pattern.isEmpty { issue(val, path, "log: needs a regex, e.g. \"log:ready on\"") }
                        else if (try? NSRegularExpression(pattern: pattern)) == nil { issue(val, path, "invalid regex '\(pattern)'") }
                        else { ready = .log(pattern) }
                    } else { issue(val, path, "unknown ready check '\(s)' (use http, port, none or log:<regex>)") }
                }
            case "ready_timeout":
                if let t = val.float ?? val.int.map(Double.init), t > 0 { readyTimeout = t }
                else { issue(val, path, "must be a positive number of seconds") }
            default:
                warn(k, "unknown key '\(path)' (ignored)")
            }
        }
        if !sawRun { issue(key, base, "missing required `run:`") }
        if let r = ready, (r == .http || r == .port), port == nil {
            issue(node, "\(base).ready", "ready: \(r.label) needs `port:` to be set")
        }
        guard issues.count == before else { return nil }

        let cwd = Self.resolveCwd(cwdRaw, dir: dir)
        return StackService(name: name, command: command, display: display, cwd: cwd, port: port, env: env,
                            dependsOn: deps, ready: ready, readyTimeout: readyTimeout, line: key.mark?.line)
    }

    static func resolveCwd(_ raw: String?, dir: URL) -> String {
        guard var r = raw else { return dir.path }
        if r == "~" || r.hasPrefix("~/") { r = NSString(string: r).expandingTildeInPath }
        let u = r.hasPrefix("/") ? URL(fileURLWithPath: r) : URL(fileURLWithPath: r, relativeTo: dir)
        return u.standardizedFileURL.path
    }

    mutating func crossChecks(_ services: [StackService]) {
        let names = Set(services.map(\.name))
        func add(_ svc: String, _ line: Int?, _ path: String, _ msg: String) {
            issues.append(StackIssue(file: file, line: line, keyPath: path, message: msg))
        }
        // unknown / self deps
        for s in services {
            for d in s.dependsOn {
                if d == s.name { add(s.name, depLines[s.name] ?? lines[s.name], "services.\(s.name).depends_on", "service depends on itself") }
                else if !names.contains(d) {
                    add(s.name, depLines[s.name] ?? lines[s.name], "services.\(s.name).depends_on",
                        "unknown dependency '\(d)' (defined services: \(services.map(\.name).joined(separator: ", ")))")
                }
            }
        }
        // duplicate ports
        var byPort: [UInt16: String] = [:]
        for s in services {
            guard let p = s.port else { continue }
            if let other = byPort[p] {
                add(s.name, portLines[s.name], "services.\(s.name).port", "port \(p) is already used by service '\(other)'")
            } else { byPort[p] = s.name }
        }
        // cycles (only among valid edges)
        let adj = Dictionary(uniqueKeysWithValues: services.map { s in (s.name, s.dependsOn.filter { names.contains($0) && $0 != s.name }) })
        if let cycle = StackPlanner.findCycle(adj, order: services.map(\.name)) {
            add(cycle[0], depLines[cycle[0]] ?? lines[cycle[0]], "services.\(cycle[0]).depends_on", "dependency cycle: \(cycle.joined(separator: " -> "))")
        }
    }
}
