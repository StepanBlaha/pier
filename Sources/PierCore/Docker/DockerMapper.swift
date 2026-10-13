import Foundation
import Darwin

public enum DockerMapper {
    /// Total wall-clock budget for talking to the Docker Engine API.
    public static let budget: TimeInterval = 0.15

    /// Published host ports → container info, via the Docker Engine API over the first reachable unix socket
    /// (DOCKER_HOST, ~/.docker/run/docker.sock, /var/run/docker.sock, ~/.orbstack/run/docker.sock, colima,
    /// Rancher Desktop, podman). Fast-fails (≤150ms) if none.
    public static func publishedPorts() -> [UInt16: DockerInfo] {
        publishedPorts(sockets: existingSockets(), budget: budget)
    }

    /// Environment-injectable variant (tests).
    public static func publishedPorts(environment: [String: String], home: String, budget: TimeInterval = DockerMapper.budget) -> [UInt16: DockerInfo] {
        publishedPorts(sockets: existingSockets(environment: environment, home: home), budget: budget)
    }

    /// Queries each socket in order until one answers `GET /containers/json`, sharing one overall budget.
    public static func publishedPorts(sockets: [String], budget: TimeInterval) -> [UInt16: DockerInfo] {
        guard !sockets.isEmpty else { return [:] }
        let start = DispatchTime.now().uptimeNanoseconds
        for path in sockets {
            let spent = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            let left = budget - spent
            if left <= 0.005 { break }
            guard let r = LocalHTTP.get(.unix(path), path: "/containers/json", budget: left), r.status == 200 else { continue }
            return parseContainers(r.body)
        }
        return [:]
    }

    // MARK: Socket discovery

    /// Candidate socket paths in priority order (not checked for existence).
    public static func candidateSockets(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        home: String = NSHomeDirectory()) -> [String] {
        var out: [String] = []
        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            let p = String(host.dropFirst("unix://".count))
            if !p.isEmpty { out.append(p) }
        }
        out += [
            "\(home)/.docker/run/docker.sock",
            "/var/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "\(home)/.rd/docker.sock",
        ]
        if let xdg = environment["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            out.append("\(xdg)/podman/podman.sock")
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Candidates that currently exist as unix sockets.
    public static func existingSockets(environment: [String: String] = ProcessInfo.processInfo.environment,
                                       home: String = NSHomeDirectory()) -> [String] {
        candidateSockets(environment: environment, home: home).filter(isSocket)
    }

    static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    // MARK: Parsing

    private struct Container: Decodable {
        struct Port: Decodable {
            var PrivatePort: Int?
            var PublicPort: Int?
            var `Type`: String?
            var IP: String?
        }
        var Id: String?
        var Names: [String]?
        var Image: String?
        var Ports: [Port]?
        var Labels: [String: String]?
    }

    /// Parses a `/containers/json` body. TCP ports with a PublicPort only; first container wins per host port.
    public static func parseContainers(_ data: Data) -> [UInt16: DockerInfo] {
        guard let containers = try? JSONDecoder().decode([Container].self, from: data) else { return [:] }
        var out: [UInt16: DockerInfo] = [:]
        for c in containers {
            guard let id = c.Id else { continue }
            var name = c.Names?.first ?? String(id.prefix(12))
            if name.hasPrefix("/") { name.removeFirst() }
            for p in c.Ports ?? [] {
                guard (p.Type ?? "tcp") == "tcp",
                      let pub = p.PublicPort, let priv = p.PrivatePort,
                      let hostPort = UInt16(exactly: pub), let containerPort = UInt16(exactly: priv),
                      out[hostPort] == nil else { continue }
                out[hostPort] = DockerInfo(
                    containerID: id, containerName: name, image: c.Image ?? "", containerPort: containerPort,
                    composeProject: c.Labels?["com.docker.compose.project"],
                    composeService: c.Labels?["com.docker.compose.service"])
            }
        }
        return out
    }
}
