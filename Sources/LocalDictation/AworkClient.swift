import AppKit
import CryptoKit
import DictationCore
import Foundation
import Network
import Security

/// awork through its API, logged in as the user with OAuth 2.1 and PKCE, with the API client the
/// awork Bulk Planner uses. Its id and secret, and the tokens after login, live in
/// `CredentialFile` (Application Support, readable only by the user, outside the repo); nothing
/// of it goes into logs or settings.
///
/// The client's registered redirect is `http://localhost:5174/auth/callback`, so for the login the
/// app answers on that port itself; the Bulk Planner backend must not be running locally then.
actor AworkClient {
    static let shared = AworkClient()

    static let apiBase = URL(string: "https://api.awork.com/api/v1")!
    /// The awork workspace that task links open in, such as "https://yourcompany.awork.com",
    /// from the environment variable `AWORK_WORKSPACE_URL`; awork's generic app address otherwise.
    static var webBase: URL {
        let configured = ProcessInfo.processInfo.environment["AWORK_WORKSPACE_URL"] ?? ""
        return URL(string: configured.isEmpty ? (DemoMode.isOn ? DemoMode.aworkWorkspace : "https://app.awork.com") : configured)!
    }
    static let redirectURI = "http://localhost:5174/auth/callback"
    static let callbackPort: NWEndpoint.Port = 5174
    static let scope = "full_access offline_access"
    static let keychainService = "localdictation-awork"

    enum Failure: Error, CustomStringConvertible {
        case missingClient
        case notLoggedIn
        case login(String)
        case http(Int, String)

        var description: String {
            switch self {
            case .missingClient: return "The awork API client is not set up (awork-credentials.json or the Keychain)."
            case .notLoggedIn: return "Not logged in to awork."
            case .login(let reason): return "awork login failed: \(reason)"
            case .http(let status, let body): return "awork answered \(status): \(body)"
            }
        }
    }

    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    struct Project: Identifiable, Hashable {
        let id: String
        let name: String
        let key: String
        let company: String
    }

    struct Task: Identifiable, Hashable {
        let id: String
        let name: String
        let identifier: String
    }

    struct User: Identifiable, Hashable {
        let id: String
        let firstName: String
        let lastName: String
        var name: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }
    }

    private var tokens: Tokens?
    private var refreshing: _Concurrency.Task<Tokens, Error>?
    /// When set, every call goes through the awork MCP server in Claude Code with this agent,
    /// instead of the app's own login (Settings › Connectors).
    private var mcpAgent: ClaudeAgent?

    var usesMCP: Bool { mcpAgent != nil }

    /// Switches between the own API client (nil) and the awork MCP.
    func useMCP(_ agent: ClaudeAgent?) {
        if (agent == nil) != (mcpAgent == nil) { mcpProjects = nil }
        mcpAgent = agent
    }

    /// The tools the MCP transport may call: the two script runners and the reader of stored results.
    static let mcpTools = ["mcp__awork__awork_query", "mcp__awork__awork_action", "mcp__awork__continue_reading"]

    var isLoggedIn: Bool {
        DemoMode.isOn || usesMCP || loadTokens() != nil
    }

    // MARK: Login

    /// Opens the awork login in the browser and waits for the redirect.
    func login() async throws {
        if DemoMode.isOn { return }
        if usesMCP { throw Failure.login("awork runs through the awork MCP; its login is managed in Claude Code.") }
        guard let clientID = CredentialFile.read("client-id") else { throw Failure.missingClient }
        let verifier = Self.randomURLSafe(bytes: 64)
        let state = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        var components = URLComponents(url: Self.apiBase.appendingPathComponent("accounts/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        let receiver = CallbackReceiver(port: Self.callbackPort)
        let waiting = _Concurrency.Task { try await receiver.waitForCallback(timeout: 300) }
        try await receiver.ready()
        await MainActor.run { _ = NSWorkspace.shared.open(components.url!) }
        let query = try await waiting.value
        guard query["state"] == state else { throw Failure.login("the answer did not belong to this login") }
        guard let code = query["code"] else { throw Failure.login(query["error_description"] ?? query["error"] ?? "no code") }
        let tokens = try await requestTokens([
            "grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirectURI, "code_verifier": verifier,
        ])
        save(tokens)
        AppLog.info("logged in to awork")
    }

    /// Whether the own login holds tokens, whatever the transport.
    var hasOwnLogin: Bool { DemoMode.isOn || loadTokens() != nil }

    func logout() {
        tokens = nil
        CredentialFile.delete("tokens")
    }

    // MARK: API

    func me() async throws -> User {
        let object = try await request("GET", "users/me") as? [String: Any] ?? [:]
        return Self.user(object)
    }

    /// The last project list read through the MCP, which takes seconds instead of milliseconds.
    private var mcpProjects: (loaded: Date, list: [Project])?

    /// Open projects, by name. Through the MCP the list is kept for 15 minutes.
    func projects() async throws -> [Project] {
        if usesMCP, let mcpProjects, Date().timeIntervalSince(mcpProjects.loaded) < 15 * 60 { return mcpProjects.list }
        let list = try await readProjects()
        if usesMCP { mcpProjects = (Date(), list) }
        return list
    }

    private func readProjects() async throws -> [Project] {
        try await paged("projects").compactMap { object -> Project? in
            guard let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
            if object["closedOn"] as? String != nil { return nil }
            let status = (object["projectStatus"] as? [String: Any])?["type"] as? String ?? ""
            if ["closed", "completed", "cancelled", "canceled", "done", "archived"].contains(status.lowercased()) { return nil }
            let company = (object["company"] as? [String: Any])?["name"] as? String ?? ""
            return Project(id: id, name: name, key: object["projectKey"] as? String ?? object["key"] as? String ?? "", company: company)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The open top-level tasks of a project, which can take subtasks.
    func parentCandidates(project: String) async throws -> [Task] {
        try await paged("projects/\(project)/projecttasks").compactMap { object -> Task? in
            guard let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
            if object["parentId"] as? String != nil { return nil }
            if ((object["taskStatus"] as? [String: Any])?["type"] as? String)?.lowercased() == "done" { return nil }
            return Task(id: id, name: name, identifier: object["taskIdentifier"] as? String ?? "")
        }
    }

    func users() async throws -> [User] {
        try await paged("users").map(Self.user).filter { !$0.id.isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Creates a task in `project`, as a subtask of `parent` when given, and assigns it. `planned`
    /// is the time budget in seconds, as awork stores it.
    func createTask(name: String, description: String, project: String, parent: String?, start: Date? = nil, due: Date?,
                    planned: Int? = nil, assignee: String?) async throws -> Task {
        var body: [String: Any] = ["name": name, "description": description, "baseType": "projecttask", "entityId": project]
        if let parent { body["parentId"] = parent }
        if let start { body["startOn"] = ISO8601DateFormatter().string(from: start) }
        if let due { body["dueOn"] = ISO8601DateFormatter().string(from: due) }
        if let planned, planned > 0 { body["plannedDuration"] = planned }
        let created = try await request("POST", "tasks", body: body) as? [String: Any] ?? [:]
        guard let id = created["id"] as? String ?? created["taskId"] as? String else { throw Failure.http(200, "no task id") }
        if let assignee {
            _ = try await request("POST", "tasks/\(id)/setassignees", body: [assignee])
        }
        return Task(id: id, name: name, identifier: created["taskIdentifier"] as? String ?? "")
    }

    static func taskURL(_ task: Task) -> URL {
        webBase.appendingPathComponent("tasks/\(task.id)/details")
    }

    // MARK: Transport

    /// Sends a call the assistant prepared and the user confirmed; `body` is JSON text or empty.
    func perform(_ call: AworkCall) async throws {
        guard call.isAllowed else { throw Failure.http(0, "call not allowed: \(call.method) \(call.path)") }
        let body = call.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = body.isEmpty ? nil : try JSONSerialization.jsonObject(with: Data(body.utf8), options: [.fragmentsAllowed])
        _ = try await request(call.method.uppercased(), call.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), body: object)
    }

    private func request(_ method: String, _ path: String, body: Any? = nil) async throws -> Any? {
        // Demo mode answers from invented data and never opens a connection.
        if DemoMode.isOn { return try await DemoAwork.shared.answer(method: method, path: path, body: body) }
        if let mcpAgent {
            return try await Self.viaMCP(AworkScript.request(method: method, path: path, body: body), write: method.uppercased() != "GET",
                                         intent: "\(method.uppercased()) \(path.split(separator: "?").first ?? "")", agent: mcpAgent)
        }
        var attempt = 0
        while true {
            let token = try await accessToken()
            var request = URLRequest(url: Self.url(path))
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // A 429 was not processed, so a retry is safe, also for writes.
            if status == 429 && attempt < 2 {
                attempt += 1
                let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after") ?? "") ?? 2
                try await _Concurrency.Task.sleep(nanoseconds: UInt64(min(15, max(1, wait)) * 1_000_000_000))
                continue
            }
            guard (200..<300).contains(status) else {
                throw Failure.http(status, String(decoding: data.prefix(200), as: UTF8.self))
            }
            return data.isEmpty ? nil : try JSONSerialization.jsonObject(with: data)
        }
    }

    /// All pages of a list; awork pages start at 1.
    private func paged(_ path: String) async throws -> [[String: Any]] {
        if let mcpAgent, !DemoMode.isOn {
            return try await Self.viaMCP(AworkScript.paged(path: path), write: false, intent: "List \(path)", agent: mcpAgent)
                as? [[String: Any]] ?? []
        }
        var all: [[String: Any]] = []
        var seen = Set<String>()
        for page in 1...25 {
            let items = try await request("GET", "\(path)?pageSize=500&page=\(page)") as? [[String: Any]] ?? []
            let fresh = items.filter { seen.insert(($0["id"] as? String ?? UUID().uuidString).lowercased()).inserted }
            all += fresh
            if items.count < 500 || fresh.isEmpty { break }
        }
        return all
    }

    /// Runs one script through the awork MCP and returns the stored result, read from the tool
    /// results so the model never has to repeat the data.
    private static func viaMCP(_ script: String, write: Bool, intent: String, agent: ClaudeAgent) async throws -> Any? {
        let started = Date()
        let run = try await agent.runCollecting(AworkScript.prompt(script: script, write: write, intent: intent), kind: "awork-mcp")
        let payload = try AworkScript.payload(from: run.toolResults)
        AppLog.info(String(format: "awork via MCP: %@ in %.1f s", intent, Date().timeIntervalSince(started)))
        return payload
    }

    // MARK: Tokens

    private func accessToken() async throws -> String {
        guard var current = loadTokens() else { throw Failure.notLoggedIn }
        if current.expiresAt.timeIntervalSinceNow < 120 {
            current = try await refreshed(current)
        }
        return current.accessToken
    }

    /// One refresh at a time: awork refresh tokens work only once.
    private func refreshed(_ current: Tokens) async throws -> Tokens {
        if let refreshing { return try await refreshing.value }
        guard let refresh = current.refreshToken else { throw Failure.notLoggedIn }
        let task = _Concurrency.Task { try await self.requestTokens(["grant_type": "refresh_token", "refresh_token": refresh]) }
        refreshing = task
        defer { refreshing = nil }
        let tokens = try await task.value
        save(tokens)
        return tokens
    }

    private func requestTokens(_ parameters: [String: String]) async throws -> Tokens {
        guard let clientID = CredentialFile.read("client-id") else { throw Failure.missingClient }
        var form = parameters
        form["client_id"] = clientID
        if let secret = CredentialFile.read("client-secret") { form["client_secret"] = secret }
        var request = URLRequest(url: Self.apiBase.appendingPathComponent("accounts/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String else {
            // The body can echo parameters, so only the status is reported.
            throw Failure.login("token request answered \(status)")
        }
        let lifetime = (object["expires_in"] as? Double) ?? 86_400
        return Tokens(accessToken: access, refreshToken: object["refresh_token"] as? String,
                      expiresAt: Date().addingTimeInterval(lifetime))
    }

    private func loadTokens() -> Tokens? {
        if let tokens { return tokens }
        guard let text = CredentialFile.read("tokens"),
              let decoded = try? JSONDecoder().decode(Tokens.self, from: Data(text.utf8)) else { return nil }
        tokens = decoded
        return decoded
    }

    private func save(_ tokens: Tokens) {
        self.tokens = tokens
        if let data = try? JSONEncoder().encode(tokens) {
            CredentialFile.write(String(decoding: data, as: UTF8.self), for: "tokens")
        }
    }

    // MARK: Helpers

    /// The API address for `path`, which may carry a query ("projects?page=1"); appending it as a
    /// path component would encode the "?" and the request would not be found.
    static func url(_ path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var components = URLComponents(url: apiBase.appendingPathComponent(parts[0]), resolvingAgainstBaseURL: false)!
        if parts.count > 1 { components.percentEncodedQuery = parts[1] }
        return components.url!
    }

    private static func user(_ object: [String: Any]) -> User {
        User(id: object["id"] as? String ?? object["userId"] as? String ?? "",
             firstName: object["firstName"] as? String ?? "", lastName: object["lastName"] as? String ?? "")
    }

    private static func randomURLSafe(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension Data {
    var base64URLEncoded: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Answers the OAuth redirect on localhost once and hands over its query.
private final class CallbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finished = false

    init(port: NWEndpoint.Port) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        listener = try! NWListener(using: parameters)
    }

    /// Returns once the port is open, so the browser is only sent there afterwards.
    func ready() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.resumeReady(nil)
                case .failed(let error): self.resumeReady(AworkClient.Failure.login("port 5174 is in use (\(error))"))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: .global())
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(AworkClient.Failure.login("no answer from the browser within five minutes")))
            }
        }
    }

    private func resumeReady(_ error: Error?) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            guard target.hasPrefix("/auth/callback") else {
                connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            let items = URLComponents(string: "http://localhost" + target)?.queryItems ?? []
            let query = Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
            let page = "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>LocalDictation ist mit awork verbunden.</h2><p>Du kannst dieses Fenster schließen.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            self?.finish(.success(query))
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        lock.unlock()
        listener.cancel()
        continuation?.resume(with: result)
    }
}

/// The awork login in `~/Library/Application Support/LocalDictation/awork-credentials.json`, a JSON
/// object of strings that only the user can read (mode 600), outside the repo.
///
/// The Keychain asked for the login password whenever the app read it after a rebuild: the app is
/// signed without an Apple team id, so macOS ties "Always Allow" to the exact build. A value
/// missing from the file is taken from the Keychain once, where earlier versions kept it.
enum CredentialFile {
    static var url: URL { AppPaths.supportDirectory.appendingPathComponent("awork-credentials.json") }

    /// Reads and writes go one at a time, so a token renewal and a lookup running together never
    /// see a half-replaced file.
    private static let lock = NSLock()

    static func read(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let value = load()[key] { return value }
        // The login Keychain is asked only before the file exists: macOS asks for the password
        // again after every new build of the app, so a missing value (such as an optional client
        // secret) must not send each read there.
        guard !FileManager.default.fileExists(atPath: url.path),
              let value = Keychain.read(service: AworkClient.keychainService, account: key) else { return nil }
        var values = load()
        values[key] = value
        save(values)
        return value
    }

    static func write(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var values = load()
        values[key] = value
        save(values)
    }

    static func delete(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        var values = load()
        values[key] = nil
        save(values)
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    private static func save(_ values: [String: String]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        writePrivate(data, to: url)
    }

    /// Writes a new file with mode 600 and moves it over the old one, so the values are never
    /// readable by others, not even for a moment.
    static func writePrivate(_ data: Data, to target: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".credentials-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if manager.fileExists(atPath: target.path) {
            _ = try? manager.replaceItemAt(target, withItemAt: temporary)
        } else {
            try? manager.moveItem(at: temporary, to: target)
        }
    }
}

/// Generic passwords in the login Keychain, where earlier versions kept the awork login.
enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
