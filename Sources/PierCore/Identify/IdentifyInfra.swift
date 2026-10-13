import Foundation

struct InfraRule {
    let name: String
    /// Exact process-name / executable-basename matches.
    var names: [String] = []
    /// Substrings of the lowercased argv (for JVM / beam services whose process name is "java"/"beam.smp").
    var argFragments: [String] = []
    /// Substrings of the lowercased executable path.
    var pathFragments: [String] = []
    /// Ports that identify the service when the process has no dev context (or is docker-proxied).
    var ports: [UInt16] = []
    /// Ports that identify the service only when proxied by docker/orbstack (too generic otherwise).
    var dockerPorts: [UInt16] = []
    /// Known not to speak HTTP, so the prober is skipped.
    var nonHTTP = false
    /// Ports of this service that DO speak HTTP even when `nonHTTP`.
    var httpPorts: Set<UInt16> = []
}

enum InfraDetector {
    static let rules: [InfraRule] = [
        InfraRule(name: "PostgreSQL", names: ["postgres", "postmaster"], ports: [5432], nonHTTP: true),
        InfraRule(name: "Redis", names: ["redis-server", "redis-stack-server"], ports: [6379], nonHTTP: true),
        InfraRule(name: "Valkey", names: ["valkey-server"], nonHTTP: true),
        InfraRule(name: "MongoDB", names: ["mongod", "mongos"], ports: [27017], nonHTTP: true),
        InfraRule(name: "MariaDB", names: ["mariadbd", "mariadbd-safe"], nonHTTP: true),
        InfraRule(name: "MySQL", names: ["mysqld", "mysqld_safe"], ports: [3306], nonHTTP: true),
        InfraRule(name: "Memcached", names: ["memcached"], ports: [11211], nonHTTP: true),
        InfraRule(name: "Ollama", names: ["ollama"], pathFragments: ["/ollama.app/"], ports: [11434]),
        InfraRule(name: "LM Studio", names: ["lm studio", "lm-studio", "lms"], pathFragments: ["/lm studio.app/"], dockerPorts: [1234]),
        InfraRule(name: "OpenSearch", names: ["opensearch"], argFragments: ["org.opensearch.bootstrap"]),
        InfraRule(name: "Elasticsearch", names: ["elasticsearch"], argFragments: ["org.elasticsearch.bootstrap"], ports: [9200]),
        InfraRule(name: "RabbitMQ", names: ["rabbitmq-server"], argFragments: ["rabbitmq", "rabbit@"], ports: [5672, 15672, 15692, 25672],
                  nonHTTP: true, httpPorts: [15672, 15692]),
        InfraRule(name: "MinIO", names: ["minio"], dockerPorts: [9000, 9001]),
        InfraRule(name: "Supabase", names: ["supabase"], dockerPorts: [54321, 54322, 54323, 54324]),
        InfraRule(name: "ClickHouse", names: ["clickhouse", "clickhouse-server"], ports: [8123]),
        InfraRule(name: "Meilisearch", names: ["meilisearch"], ports: [7700]),
        InfraRule(name: "NATS", names: ["nats-server"], ports: [4222, 8222], nonHTTP: true, httpPorts: [8222]),
        InfraRule(name: "Kafka", names: ["kafka"], argFragments: ["kafka.kafka", "kafka.server"], ports: [9092], nonHTTP: true),
        InfraRule(name: "Mailpit", names: ["mailpit", "mailhog"], ports: [8025], dockerPorts: [1025]),
    ]

    static let dockerPrefixes = ["docker", "com.docker", "vpnkit", "orbstack", "colima", "limactl"]
    static let dockerPaths = ["/docker.app/", "/orbstack.app/", "/orbstack/"]

    static func isDockerProxy(_ f: ProcFacets) -> Bool {
        f.hasNamePrefix(anyOf: dockerPrefixes) || f.pathContains(anyOf: dockerPaths)
    }

    static func rule(named name: String) -> InfraRule? { rules.first { $0.name == name } }

    /// Name match beats port match. Port-only matches are skipped for processes that look like
    /// someone's dev server (project cwd, JS/Python runtime, known framework), unless docker-proxied.
    static func match(_ f: ProcFacets, port: UInt16, isDocker: Bool, hasDevContext: Bool, isAccessible: Bool) -> InfraRule? {
        let hay = f.haystack
        let isVM = f.isNamed(anyOf: ["java", "beam.smp", "beam"])
        if let r = rules.first(where: { r in
            f.isNamed(anyOf: r.names) || r.pathFragments.contains(where: { f.exe.contains($0) })
                || (isVM && r.argFragments.contains(where: hay.contains))
        }) { return r }

        if isDocker, let r = rules.first(where: { $0.ports.contains(port) || $0.dockerPorts.contains(port) }) { return r }
        if !isDocker, (!hasDevContext || !isAccessible), let r = rules.first(where: { $0.ports.contains(port) }) { return r }
        return nil
    }
}
