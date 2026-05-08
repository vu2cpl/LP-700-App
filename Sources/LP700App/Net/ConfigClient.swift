import Foundation

// REST helpers for /api/config and /api/log-level on the LP-700 server.
struct ServerConfig: Decodable, Equatable {
    var backend: String
    var allowControl: Bool
    var title: String

    enum CodingKeys: String, CodingKey {
        case backend
        case allowControl = "allow_control"
        case title
    }
}

struct LogLevelConfig: Codable, Equatable {
    var level: String
}

actor ConfigClient {
    private var baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func setBaseURL(_ url: URL) {
        baseURL = url
    }

    func fetchConfig() async throws -> ServerConfig {
        try await get(path: "/api/config")
    }

    func fetchLogLevel() async throws -> LogLevelConfig {
        try await get(path: "/api/log-level")
    }

    func setLogLevel(_ level: String) async throws -> LogLevelConfig {
        try await postJSON(path: "/api/log-level", body: LogLevelConfig(level: level))
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await session.data(for: req)
        try checkOK(resp)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postJSON<Body: Encodable, R: Decodable>(path: String, body: Body) async throws -> R {
        let url = baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        try checkOK(resp)
        return try JSONDecoder().decode(R.self, from: data)
    }

    private func checkOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
