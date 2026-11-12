import Foundation
import HTTPTypes
import OpenAPIRuntime
@testable import GrimmoryAPI

/// A scripted Grimmory server. Each test sets `route` to answer requests; every request is recorded.
actor FakeGrimmory: ClientTransport {
    struct Recorded: Sendable {
        var method: HTTPRequest.Method
        var path: String
        var authorization: String?
        var body: String?
    }

    typealias Route = @Sendable (Recorded) async throws -> (status: Int, json: String)

    private(set) var requests: [Recorded] = []
    private var route: Route

    init(route: @escaping Route = { _ in (404, "{}") }) {
        self.route = route
    }

    func setRoute(_ route: @escaping Route) { self.route = route }

    func count(path: String) -> Int { requests.filter { $0.path.hasPrefix(path) }.count }

    nonisolated func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String)
        async throws -> (HTTPResponse, HTTPBody?) {
        var text: String?
        if let body { text = try await String(collecting: body, upTo: 1 << 20) }
        let recorded = Recorded(method: request.method, path: request.path ?? "",
                                authorization: request.headerFields[.authorization], body: text)
        let (status, json) = try await handle(recorded)
        var response = HTTPResponse(status: .init(code: status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(json))
    }

    private func handle(_ recorded: Recorded) async throws -> (status: Int, json: String) {
        requests.append(recorded)
        return try await route(recorded)
    }
}

enum Fixtures {
    static let server = URL(string: "https://books.example.com")!

    static func tokenJSON(access: String, refresh: String, expires: Int = 7200) -> String {
        #"{"accessToken":"\#(access)","refreshToken":"\#(refresh)","expires":\#(expires)}"#
    }

    static let userJSON = """
    {"id":7,"username":"alice","name":"Alice","email":"alice@example.com","defaultPassword":false,
     "permissions":{"admin":false,"canDownload":true,"canUpload":false,"canEditMetadata":true,"canEmailBook":true}}
    """

    static func tokens(access: String = "A1", refresh: String = "R1", expiresIn: TimeInterval = 3600) -> GrimmoryTokens {
        GrimmoryTokens(accessToken: access, refreshToken: refresh, accessTokenExpiry: Date().addingTimeInterval(expiresIn))
    }
}
