import Foundation

/// Client for the Comet X's undocumented kvmd-derived HTTP API.
///
/// See CLAUDE.md for the verified endpoint list. Two rules that matter:
///   1. `set_active` takes the port ID as a float ("1.4"), never a channel index.
///   2. A 200 response can still carry `{"ok": false}` — always check it.
public actor CometClient {
    public let host: String
    public let user: String
    private let keychain: Keychain
    private let session: URLSession

    public init(
        host: String = "glkvm.local",
        user: String = "admin",
        keychain: Keychain = Keychain()
    ) {
        self.host = host
        self.user = user
        self.keychain = keychain
        self.session = URLSession(
            configuration: .ephemeral,
            delegate: SelfSignedTrustDelegate(allowedHost: host),
            delegateQueue: nil
        )
    }

    // MARK: - Reads

    public func info() async throws -> DeviceInfo {
        let result = try await get("/api/info")
        guard let system = result["system"] as? [String: Any] else {
            throw CometError.decoding("info.system")
        }
        let kvmd = system["kvmd"] as? [String: Any]
        let kernel = system["kernel"] as? [String: Any]
        let platform = system["platform"] as? [String: Any]
        let health = result["health"] as? [String: Any]
        let temp = (health?["temp"] as? [String: Any])?["cpu"] as? Double

        return DeviceInfo(
            kvmdVersion: kvmd?["version"] as? String ?? "?",
            kernelRelease: kernel?["release"] as? String ?? "?",
            platformModel: platform?["model"] as? String ?? "?",
            cpuTempC: temp
        )
    }

    public func switchState() async throws -> SwitchState {
        let result = try await get("/api/switch")

        guard let summary = result["summary"] as? [String: Any],
              let activeID = summary["active_id"] as? String,
              let activeChannel = summary["active_port"] as? Int,
              let model = result["model"] as? [String: Any],
              let rawPorts = model["ports"] as? [[String: Any]]
        else { throw CometError.decoding("switch.summary/model.ports") }

        let videoLinks = (result["video"] as? [String: Any])?["links"] as? [Bool] ?? []
        let usbLinks = (result["usb_otg"] as? [String: Any])?["links"] as? [Bool] ?? []
        let edidsUsed = (result["edids"] as? [String: Any])?["used"] as? [String] ?? []

        let ports: [SwitchState.Port] = rawPorts.compactMap { raw in
            guard let id = raw["id"] as? String,
                  let channel = raw["channel"] as? Int
            else { return nil }
            return SwitchState.Port(
                id: id,
                channel: channel,
                name: raw["name"] as? String ?? "",
                videoLinked: videoLinks.indices.contains(channel) ? videoLinks[channel] : false,
                usbLinked: usbLinks.indices.contains(channel) ? usbLinks[channel] : false
            )
        }

        return SwitchState(
            activeID: activeID,
            activeChannel: activeChannel,
            synced: summary["synced"] as? Bool ?? false,
            ports: ports,
            edidsInUse: edidsUsed
        )
    }

    // MARK: - Writes

    /// Switches the KVM to `port`.
    ///
    /// WARNING: this moves keyboard, mouse and video away from this Mac. Once
    /// switched away, this app can no longer be driven from the Mac's own
    /// keyboard — see the switch-back constraint in CLAUDE.md.
    public func setActive(_ port: PortNumber) async throws {
        _ = try await post("/api/switch/set_active", query: ["port": port.apiValue])
    }

    /// Convenience wrapper that validates a 1-based port number.
    public func setActive(portNumber: Int) async throws {
        guard let port = PortNumber(portNumber) else {
            throw CometError.badPort(portNumber)
        }
        try await setActive(port)
    }

    public func checkAuth() async throws -> Bool {
        _ = try await get("/api/auth/check")
        return true
    }

    // MARK: - Transport

    private func url(_ path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    private func get(_ path: String) async throws -> [String: Any] {
        try await send(makeRequest(url(path), method: "GET"))
    }

    private func post(_ path: String, query: [String: String]) async throws -> [String: Any] {
        try await send(makeRequest(url(path, query: query), method: "POST"))
    }

    private func makeRequest(_ url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        // kvmd accepts stateless per-request credential headers.
        request.setValue(user, forHTTPHeaderField: "X-KVMD-User")
        request.setValue(try keychain.password(), forHTTPHeaderField: "X-KVMD-Passwd")
        return request
    }

    /// Sends the request and unwraps the kvmd `{ok, result}` envelope.
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 401 { throw CometError.unauthorized }

        // Some failures (a malformed port, notably) come back as non-JSON.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CometError.http(
                status: status,
                body: String(data: data, encoding: .utf8) ?? "<binary>"
            )
        }

        // A 200 with ok:false is possible — this is the important check.
        if json["ok"] as? Bool != true {
            let result = json["result"] as? [String: Any]
            throw CometError.apiError(
                code: result?["error"] as? String ?? "Unknown",
                message: result?["error_msg"] as? String ?? "no message"
            )
        }

        guard (200...299).contains(status) else {
            throw CometError.http(status: status, body: "ok:true but HTTP \(status)")
        }

        return json["result"] as? [String: Any] ?? [:]
    }
}

/// Accepts the Comet X's self-signed LAN certificate — and nothing else.
///
/// TODO: pin the device's actual certificate rather than trusting it blindly.
/// This is deliberately scoped to one hostname so the exception cannot leak to
/// other hosts. Do not widen it.
private final class SelfSignedTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    private let allowedHost: String

    init(allowedHost: String) {
        self.allowedHost = allowedHost
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == allowedHost,
              let trust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
