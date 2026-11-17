import SwiftUI
import TraceCore

#if DEBUG
import Alamofire
import TraceAlamofire
import TraceUI

@MainActor
final class DemoModel: ObservableObject {
    let diagnostics = NetworkDiagnostics()
    let session: Session
    @Published var isRunning = false
    @Published var hasRun = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        session = Session(configuration: configuration, eventMonitors: [diagnostics.monitor])
    }
    func run() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; hasRun = true }
        await withTaskGroup(of: Void.self) { group in
            for path in ["/v1/config", "/v1/user/profile", "/v1/feed", "/v1/search", "/v1/notifications"] {
                group.addTask { [session] in
                    _ = await session.request("https://trace.invalid\(path)", headers: [.authorization(bearerToken: "demo-private-token")])
                        .validate().serializingDecodable(DemoFeed.self).response
                }
            }
            group.addTask { [session] in
                _ = await session.request("https://trace.invalid/v1/auth/login", method: .post,
                                          parameters: ["email": "demo@example.invalid", "password": "demo-password"], encoder: JSONParameterEncoder.default)
                    .validate().serializingDecodable(DemoFeed.self).response
            }
        }
    }
}

struct DemoFeed: Decodable, Sendable {
    struct Item: Decodable, Sendable { let id: Int; let title: String }
    let items: [Item]
}

/// Local URLProtocol fixture: requests go through Alamofire, but no data leaves the device.
final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "trace.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delay = request.url?.path == "/v1/search" ? 1.2 : 0.2
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock(); let isStopped = stopped; lock.unlock()
            guard !isStopped, let url = request.url else { return }
            if url.path == "/v1/search" {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
            }
            let status = url.path == "/v1/user/profile" ? 401 : 200
            let body: String
            switch url.path {
            case "/v1/feed": body = #"{"items":[{"id":1,"title":"Hello"},{"id":2,"title":"Swift"},{"id":3,"title":null}]}"#
            case "/v1/user/profile": body = #"{"code":"TOKEN_EXPIRED","message":"Please sign in again"}"#
            case "/v1/auth/login": body = #"{"items":[],"accessToken":"demo-response-token"}"#
            default: body = #"{"items":[{"id":1,"title":"Trace demo"}]}"#
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json", "X-Demo": "local-fixture"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

struct DemoRootView: View {
    @StateObject private var model = DemoModel()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(TraceLocalization.text("Local mock responses; no server access"), systemImage: "testtube.2")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.isRunning ? TraceLocalization.text("Running…") : TraceLocalization.text("Send again")) { Task { await model.run() } }
                    .font(.caption).disabled(model.isRunning)
            }.padding(.horizontal).padding(.vertical, 10)
            Divider()
            NetworkDiagnosticsView(store: model.diagnostics.store)
        }
        .task { if !model.hasRun { await model.run() } }
    }
}
#endif

@main
struct TraceExampleApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            DemoRootView()
            #else
            Text(TraceLocalization.text("Diagnostics and the panel are disabled in Release builds."))
            #endif
        }
    }
}
