import AppKit
import CryptoKit
import Network
import Security
import ArchiveCore

struct OAuthClient: Codable {
    let client_id: String
    let client_secret: String?
}
private struct ClientFile: Decodable { let installed: OAuthClient }
private struct SavedLogin: Codable {
    let refreshToken: String
    let email: String
}
private struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Double
    let refresh_token: String?
}

@MainActor final class GoogleLogin: ObservableObject {
    @Published var email = ""
    @Published var configured = false
    @Published var busy = false
    @Published var storageIssue: String?
    private let store: SecretStore
    private let http: HTTPTransport
    private var client: OAuthClient?
    private var saved: SavedLogin?
    private var accessToken: String?
    private var expiry = Date.distantPast
    private var callback: LoopbackLogin?

    init(store: SecretStore = KeychainStore(), http: HTTPTransport = SecureHTTP()) {
        self.store = store; self.http = http
        do {
            if let data = try store.read("oauth-client") {
                client = try JSONDecoder().decode(OAuthClient.self, from: data); configured = true
            }
            if let data = try store.read("oauth-login") {
                saved = try JSONDecoder().decode(SavedLogin.self, from: data); email = saved!.email
            }
        } catch { storageIssue = error.localizedDescription }
    }
    func importClient(_ url: URL) throws {
        let data = try LocalInput.read(url)
        guard data.count < 64 * 1024 else { throw ArchiveError("Choose the small Desktop app OAuth JSON file from Google Cloud.") }
        let imported: OAuthClient
        do { imported = try JSONDecoder().decode(ClientFile.self, from: data).installed }
        catch { throw ArchiveError("This is not a Desktop app OAuth configuration. Service account keys and Web clients are not supported.") }
        guard imported.client_id.hasSuffix(".apps.googleusercontent.com"), !imported.client_id.contains(where: { $0.isWhitespace }) else {
            throw ArchiveError("The OAuth client ID is invalid.")
        }
        try signOut()
        try store.write("oauth-client", data: JSONEncoder().encode(imported))
        client = imported; configured = true; storageIssue = nil
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ArchiveError("Could not create secure login information.")
        }
        return base64url(Data(bytes))
    }
    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
    private func exchange(_ values: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.form(values)
        let (data, response) = try await http.send(req)
        guard response.statusCode == 200 else {
            if [408, 429].contains(response.statusCode) || (500...599).contains(response.statusCode) {
                throw ServiceFailure(status: response.statusCode)
            }
            throw AuthenticationFailure("Google could not authorize this login (HTTP \(response.statusCode)). Sign in again; check the Desktop client and consent-screen test users if it persists.")
        }
        guard let result = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !result.access_token.isEmpty, result.expires_in.isFinite, result.expires_in > 0 else {
            throw AuthenticationFailure("Google returned incomplete login information. Sign in again.")
        }
        return result
    }
    func signIn() async throws {
        guard let client else { throw ArchiveError("Import the Google Desktop app configuration first.") }
        busy = true; defer { busy = false; callback = nil }
        let verifier = try Self.random(), state = try Self.random()
        let receiver = try LoopbackLogin(state: state)
        callback = receiver
        defer { receiver.stop() }
        let redirect = try await receiver.start()
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            .init(name: "client_id", value: client.client_id), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "state", value: state),
            .init(name: "code_challenge", value: Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent select_account"),
            .init(name: "scope", value: "https://www.googleapis.com/auth/devstorage.read_write https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/cloudplatformprojects.readonly")
        ]
        guard NSWorkspace.shared.open(url.url!) else { throw ArchiveError("Could not open your browser for Google login.") }
        let code = try await receiver.code()
        try Task.checkCancellation()
        var values = ["client_id": client.client_id, "code": code, "code_verifier": verifier,
                      "redirect_uri": redirect, "grant_type": "authorization_code"]
        values["client_secret"] = client.client_secret
        let tokens = try await exchange(values)
        var info = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        info.setValue("Bearer " + tokens.access_token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.send(info)
        guard response.statusCode == 200,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["email"] as? String, !account.isEmpty,
              let refresh = tokens.refresh_token else { throw ArchiveError("Google did not return account information and offline access. Try signing in again.") }
        try Task.checkCancellation()
        // A different account must never inherit a previous account's resumable capabilities.
        try store.clearUploads()
        let login = SavedLogin(refreshToken: refresh, email: account)
        try store.write("oauth-login", data: JSONEncoder().encode(login))
        saved = login; email = account; accessToken = tokens.access_token
        expiry = Date().addingTimeInterval(tokens.expires_in - 60)
    }
    func token(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let accessToken, expiry > Date() { return accessToken }
        guard let client, let saved else { throw AuthenticationFailure("Sign in to Google before checking or uploading.") }
        var values = ["client_id": client.client_id, "refresh_token": saved.refreshToken, "grant_type": "refresh_token"]
        values["client_secret"] = client.client_secret
        let result = try await exchange(values)
        if let replacement = result.refresh_token {
            let updated = SavedLogin(refreshToken: replacement, email: saved.email)
            try store.write("oauth-login", data: JSONEncoder().encode(updated))
            self.saved = updated
        }
        accessToken = result.access_token; expiry = Date().addingTimeInterval(result.expires_in - 60)
        return result.access_token
    }
    func cancel() { callback?.stop() }
    func signOut() throws {
        // Even a locked Keychain must not leave a usable login in memory after Sign out.
        defer { saved = nil; email = ""; accessToken = nil; expiry = .distantPast }
        try store.remove("oauth-login"); try store.clearUploads()
    }
}

// A random-port HTTP receiver bound ONLY to IPv4 loopback. All callbacks execute on the main queue.
@MainActor final class LoopbackLogin {
    private let listener: NWListener
    private let state: String
    private var startWaiter: CheckedContinuation<String, Error>?
    private var codeWaiter: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var timer: Task<Void, Never>?
    private var connections: [NWConnection] = []
    init(state: String) throws {
        self.state = state
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }
    func start() async throws -> String {
        try Task.checkCancellation()
        if let result { return try result.get() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                startWaiter = continuation
                listener.stateUpdateHandler = { [weak self] update in
                    Task { @MainActor in
                        guard let self else { return }
                        switch update {
                        case .ready:
                            guard let port = self.listener.port else { self.stop(); return }
                            self.startWaiter?.resume(returning: "http://127.0.0.1:\(port.rawValue)/oauth/callback")
                            self.startWaiter = nil
                        case .failed: self.finish(.failure(ArchiveError("Could not listen for Google login on this Mac.")))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.receive(connection) }
                }
                listener.start(queue: .main)
                timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finish(.failure(ArchiveError("Google login timed out. Click Sign in to try again.")))
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.stop() } })
    }
    func code() async throws -> String {
        try Task.checkCancellation()
        if let result { return try result.get() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { codeWaiter = $0 }
        }, onCancel: { [weak self] in Task { @MainActor in self?.stop() } })
    }
    func stop() { finish(.failure(CancellationError())) }
    private func finish(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value
        if let waiter = startWaiter {
            switch value {
            case .failure(let error): waiter.resume(throwing: error)
            case .success: waiter.resume(throwing: ArchiveError("Unexpected login response."))
            }
            startWaiter = nil
        }
        codeWaiter?.resume(with: value); codeWaiter = nil
        timer?.cancel(); listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }
    private func receive(_ connection: NWConnection) {
        guard connections.count < 8 else { connection.cancel(); return }
        connections.append(connection); connection.start(queue: .main)
        read(connection, buffer: Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = buffer; bytes.append(data ?? Data())
                guard bytes.count <= 16384, error == nil else { self.close(connection); return }
                if bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
                    if done { self.close(connection) } else { self.read(connection, buffer: bytes) }
                    return
                }
                let line = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")[0]
                let parts = line.split(separator: " ")
                guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/oauth/callback?"),
                      let c = URLComponents(string: "http://127.0.0.1" + parts[1]), c.path == "/oauth/callback" else {
                    self.reply(connection, status: "404 Not Found", body: "Not found.", completion: nil); return
                }
                let items = c.queryItems ?? []
                guard items.filter({ $0.name == "state" }).count == 1,
                      items.first(where: { $0.name == "state" })?.value == self.state else {
                    self.reply(connection, status: "400 Bad Request", body: "Invalid login state.", completion: nil); return
                }
                let value: Result<String, Error>
                if items.contains(where: { $0.name == "error" }) {
                    value = .failure(ArchiveError("Google login was declined. You can try again."))
                } else if items.filter({ $0.name == "code" }).count == 1,
                          let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
                    value = .success(code)
                } else { value = .failure(ArchiveError("Google returned an incomplete login response.")) }
                self.reply(connection, status: "200 OK", body: "Return to Media Archive Cloud Uploader to finish signing in. You can close this tab.") { self.finish(value) }
            }
        }
    }
    private func close(_ connection: NWConnection) {
        connection.cancel(); connections.removeAll { $0 === connection }
    }
    private func reply(_ connection: NWConnection, status: String, body: String, completion: (() -> Void)?) {
        let message = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(message.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection); completion?() }
        })
    }
}
