#if DEBUG
import Foundation
import PierCore

/// Made-up services for README screenshots (PIER_DEBUG_DEMO=1). DEBUG builds only.
enum DemoData {
    static func services() -> [Service] {
        let now = Date()
        func svc(_ port: UInt16, pid: Int32, name: String, project: String?, framework: (String, String)? = nil,
                 infra: String? = nil, kind: ServiceKind, title: String? = nil, branch: String? = nil,
                 lan: Bool = false, age: TimeInterval = 3600, cpu: Double = 0.4, rss: UInt64 = 120_000_000,
                 health: Health = .ok) -> Service {
            let proc = ProcInfo(pid: pid, ppid: 1, uid: 501, name: name, arguments: [name],
                                cwd: project.map { "/Users/demo/code/\($0)" }, startTime: now.addingTimeInterval(-age),
                                cpuPercent: cpu, rssBytes: rss)
            var s = Service(port: port, process: proc, addresses: [lan ? "0.0.0.0" : "127.0.0.1"], bindScope: lan ? .all : .loopback)
            s.kind = kind
            s.projectName = project
            s.projectPath = project.map { "/Users/demo/code/\($0)" }
            s.framework = framework.map { Framework(id: $0.0, name: $0.1) }
            s.infraName = infra
            s.gitBranch = branch
            s.lanURL = lan ? "http://192.168.1.24:\(port)" : nil
            s.probe = ProbeResult(protocolKind: infra == nil ? .http : .tcp, health: health, httpStatus: infra == nil ? 200 : nil, title: title)
            return s
        }
        return [
            svc(3000, pid: 4101, name: "node", project: "acme-store", framework: ("next", "Next.js"), kind: .devServer,
                title: "Acme Store", branch: "main", lan: true, age: 2 * 3600),
            svc(4321, pid: 4102, name: "node", project: "docs", framework: ("astro", "Astro"), kind: .devServer,
                title: "Acme Docs", branch: "content/pricing", age: 40 * 60, cpu: 1.2),
            svc(5173, pid: 4103, name: "node", project: "dashboard", framework: ("vite", "Vite"), kind: .devServer,
                title: "Dashboard", branch: "feat/charts", age: 25 * 60, cpu: 3.1),
            svc(5174, pid: 4104, name: "node", project: "dashboard", framework: ("vite", "Vite"), kind: .devServer,
                title: "Dashboard", branch: "feat/charts", age: 25 * 60),
            svc(8000, pid: 4105, name: "python3.12", project: "acme-api", framework: ("fastapi", "FastAPI"), kind: .devServer,
                title: "Acme API - Swagger UI", branch: "main", age: 5 * 3600),
            svc(8080, pid: 4106, name: "node", project: "old-prototype", framework: ("express", "Express"), kind: .devServer,
                title: "prototype", branch: "main", age: 9 * 86400, cpu: 0, rss: 80_000_000),
            svc(5432, pid: 812, name: "postgres", project: nil, infra: "PostgreSQL", kind: .infra, age: 12 * 86400),
            svc(6379, pid: 813, name: "redis-server", project: nil, infra: "Redis", kind: .infra, age: 12 * 86400),
            svc(11434, pid: 814, name: "ollama", project: nil, infra: "Ollama", kind: .infra, title: nil, age: 6 * 86400),
        ]
    }
}
#endif
