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
        keychain: Keychain? = nil
    ) {
        self.host = host
        self.user = user
        // Default to the Keychain entry matching this user, so switching the
        // configured account also switches which password gets read.
        self.keychain = keychain ?? Keychain(account: user)
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

        // Newer firmware keeps names in the web UI's config store rather than
        // on `model.ports[].name`. Best-effort: a failure here shouldn't take
        // down the whole switch state, it just means falling back to the
        // (pre-update) per-port names.
        let configNames = (try? await configPortNames()) ?? []

        let ports: [SwitchState.Port] = rawPorts.compactMap { raw in
            guard let id = raw["id"] as? String,
                  let channel = raw["channel"] as? Int
            else { return nil }
            let configName = configNames.indices.contains(channel) ? configNames[channel] : ""
            return SwitchState.Port(
                id: id,
                channel: channel,
                name: configName.isEmpty ? (raw["name"] as? String ?? "") : configName,
                videoLinked: videoLinks.indices.contains(channel) ? videoLinks[channel] : false,
                usbLinked: usbLinks.indices.contains(channel) ? usbLinks[channel] : false
            )
        }

        return SwitchState(
            activeID: activeID,
            activeChannel: activeChannel,
            synced: summary["synced"] as? Bool ?? false,
            ports: ports
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

    /// Sets a port's friendly name on the device itself.
    ///
    /// Since the 2026-10 firmware update, names live in the web UI's
    /// server-side config store (`config.port_names`, indexed by 0-based
    /// channel) — the same place the device's own "Edit Port Name" dialog
    /// writes. `set_config` replaces the WHOLE config, so this must be a
    /// read-modify-write that sends every other key back untouched, or it
    /// wipes the user's web UI settings (theme, language, tab title, …).
    ///
    /// The old `set_port_params?port=1.4&name=…` path still exists but its
    /// names are no longer shown anywhere, so it isn't used.
    public func setPortName(_ port: PortNumber, name: String) async throws {
        var config = try await serverConfig()
        var names = (config["port_names"] as? [Any])?.map { $0 as? String ?? "" } ?? []
        while names.count <= port.channel { names.append("") }
        names[port.channel] = name
        config["port_names"] = names
        _ = try await post("/api/system/set_config", json: config)
    }

    // MARK: - Web UI config store

    /// The web UI's persisted settings blob (`GET /api/system/get_config`).
    /// Throws rather than returning `[:]` on an unexpected shape, because a
    /// caller writing it back would otherwise erase every setting.
    private func serverConfig() async throws -> [String: Any] {
        let result = try await get("/api/system/get_config")
        guard let config = result["config"] as? [String: Any] else {
            throw CometError.decoding("get_config.config")
        }
        return config
    }

    /// Port names from the config store, by 0-based channel. Unset entries
    /// (or `null`s) come back as "".
    private func configPortNames() async throws -> [String] {
        let names = try await serverConfig()["port_names"] as? [Any] ?? []
        return names.map { $0 as? String ?? "" }
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

    private func post(_ path: String, json body: [String: Any]) async throws -> [String: Any] {
        var request = try makeRequest(url(path), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
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
