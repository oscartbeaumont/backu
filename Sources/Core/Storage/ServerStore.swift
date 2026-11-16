import Foundation
import Observation

struct ServerStoreSnapshot: Codable {
    var version: Int = 1
    var servers: [ServerConfig]
}

@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [ServerConfig] = []
    private var credentials: [UUID: S3Credentials] = [:]
    private var clients: [UUID: S3Client] = [:]
    private var saveTask: Task<Void, Never>?

    init(loadFromDisk: Bool = true) {
        if loadFromDisk, let snapshot = JSONFile.read(ServerStoreSnapshot.self, from: AppPaths.serversFile) {
            servers = snapshot.servers
        }
        for server in servers {
            credentials[server.id] = Keychain.load(for: server.id)
        }
    }

    var primaryServer: ServerConfig? {
        servers.first { $0.isEnabled } ?? servers.first
    }

    func server(id: UUID?) -> ServerConfig? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    func credentials(for id: UUID) -> S3Credentials? {
        credentials[id] ?? Keychain.load(for: id)
    }

    func client(for server: ServerConfig) -> S3Client? {
        if let cached = clients[server.id] { return cached }
        guard let creds = credentials(for: server.id) else { return nil }
        let client = S3Client(connection: server.connection, credentials: creds)
        clients[server.id] = client
        return client
    }

    func add(_ server: ServerConfig, credentials creds: S3Credentials) {
        servers.append(server)
        credentials[server.id] = creds
        Keychain.save(creds, for: server.id)
        persist()
    }

    func update(_ server: ServerConfig, credentials creds: S3Credentials? = nil) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        if let creds {
            credentials[server.id] = creds
            Keychain.save(creds, for: server.id)
        }
        clients[server.id] = nil
        persist()
    }

    func remove(_ server: ServerConfig) {
        servers.removeAll { $0.id == server.id }
        credentials[server.id] = nil
        clients[server.id] = nil
        Keychain.delete(for: server.id)
        persist()
    }

    func markVerified(_ id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].lastVerifiedAt = Date()
        persist()
    }

    private func persist() {
        saveTask?.cancel()
        let snapshot = ServerStoreSnapshot(servers: servers)
        saveTask = Task { [snapshot] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            try? JSONFile.write(snapshot, to: AppPaths.serversFile)
        }
    }

    func persistNow() {
        try? JSONFile.write(ServerStoreSnapshot(servers: servers), to: AppPaths.serversFile)
    }
}
