import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging

actor Server {
    private let config: WatcherConfig
    private let serveDir: URL
    private let builder: Builder

    init(alongisde builder: Builder, in serveDir: URL, withConfig config: WatcherConfig) {
        self.builder = builder
        self.serveDir = serveDir
        self.config = config
    }

    func run() async {
        let router = Router(context: BasicWebSocketRequestContext.self)

        router.get("/rebuild", use: rebuild(request:context:))
        router.get("/build/:id", use: buildStatus(request:context:))
        router.ws(
            "/build/:id/ws",
            shouldUpgrade: { request, context in .upgrade([:]) },
            onUpgrade: buildStatusWebsocket(inbound:outbound:context:)
        )
        router.add(middleware: BuildDirServer(builder: self.builder))

        let logger = Logger(label: "NoopLogger", factory: { _ in SwiftLogNoOpLogHandler() })
        let server = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(address: .hostname(self.config.ip, port: Int(self.config.port))),
            logger: logger
        )

        let addr = "\(self.config.ip):\(self.config.port)"
        print("Serving at: http://\(addr)")

        let serveRes = await Result({ try await server.run() })
        if case .failure(let err) = serveRes {
            fatalError("Failed to start server at \(addr) due to \(err)")
        }
    }

    private func rebuild(request: Request, context: BasicWebSocketRequestContext) async
        -> Response
    {
        let id = await self.builder.tryRebuild()
        return Response.redirect(to: "/build/\(id)", type: .normal)
    }

    private func buildStatus(request: Request, context: BasicWebSocketRequestContext) async throws
        -> Response
    {
        let id = try context.parameters.require("id")

        let logDivs = self.config.build_stages.enumerated().map { idx, stage in
            """
                <h1 class="build-stage-name">\(stage.name)</h1>
                <pre class="log-messages" id="log-messages-\(idx)"></pre>
                <pre class="log-error" id="log-error-\(idx)"></pre>
            """
        }.joined(separator: "")
        let document = String(decoding: PackageResources.build_html, as: UTF8.self)
            .replacingPlaceholders([
                "___ID___": id,
                "___LOG_DIVS___": logDivs,
                "___BUNDLE_JS___": WebResources.javascript,
            ])

        return Response(
            status: .ok, headers: [.contentType: "text/html; charset=utf-8"],
            body: .init(byteBuffer: .init(string: document))
        )
    }

    private func buildStatusWebsocket(
        inbound: WebSocketInboundStream, outbound: WebSocketOutboundWriter,
        context: WebSocketRouterContext<BasicWebSocketRequestContext>
    ) async throws {
        func sendMessage(_ msg: Encodable) async {
            let encodedMsg = try? JSONEncoder().encode(msg)
            if case .some(let msg) = encodedMsg {
                try? await outbound.writeTextMessage(String(decoding: msg, as: UTF8.self))
            }
        }

        let id = try context.requestContext.parameters.require("id")
        guard let parsedId = BuildId(parse: id) else { throw HTTPError.init(.notFound) }

        let buildLog: Builder.BuildLog
        if case .some(let (curId, log)) = await self.builder.subscribe(), curId == parsedId {
            // The desired build is the ongoing one
            buildLog = log
        } else {
            buildLog = await self.builder.subscribeCompleted(id: parsedId)
        }

        for logMsg in buildLog.history {
            await sendMessage(logMsg)
        }

        for await logMsg in buildLog.stream {
            await sendMessage(logMsg)
        }
    }

    private struct BuildDirServer: RouterMiddleware {
        let builder: Builder

        typealias Input = Request
        typealias Context = BasicWebSocketRequestContext
        typealias Output = Response

        func handle(
            _ request: Input, context: Context, next: (Input, Context) async throws -> Output
        )
            async throws -> Output
        {
            guard let lastBuild = await builder.last else {
                return Response.redirect(to: "/rebuild", type: .normal)
            }

            let files: FileMiddleware<Context, LocalFileSystem> = FileMiddleware(
                lastBuild.dir.path, searchForIndexHtml: true)
            let resp = try await files.handle(request, context: context, next: next)

            guard resp.headers[.contentType]?.contains("text/html") == true else {
                // Not an HTML
                return resp
            }

            guard let bodyBytes = await resp.body.collect() else {
                return resp
            }
            var bodyHtml = String(buffer: bodyBytes)

            let banner = await bannerHtml(for: lastBuild)
            let marker = "<body>"
            if let markerRange = bodyHtml.range(of: marker) {
                bodyHtml.insert(contentsOf: banner, at: markerRange.upperBound)
            } else {
                bodyHtml = banner + bodyHtml
            }

            var headers = resp.headers
            headers[.contentLength] = "\(bodyHtml.utf8.count)"
            headers[.eTag] = nil
            headers[.lastModified] = nil

            return Response(
                status: resp.status, headers: headers,
                body: .init(byteBuffer: .init(string: bodyHtml)))
        }

        func bannerHtml(for serveBuild: Builder.CompletedBuild) async -> String {
            func anchor(to link: String, displaying text: String) -> String {
                #"<a target="_blank" href="\#(link)">\#(text)</a>"#
            }

            func buildLink(for id: BuildId, displaying text: String) -> String {
                anchor(to: "/build/\(id)", displaying: text)
            }

            let serveBuildLink = buildLink(for: serveBuild.id, displaying: "build \(serveBuild.id)")

            let bannerMsg =
                switch await self.builder.currentId {
                    case .some(let curId):
                        "You are viewing \(serveBuildLink). A rebuild is in progress; \(buildLink(for: curId, displaying: "click here")) to see its status."
                    case .none:
                        "You are viewing \(serveBuildLink), which finished at \(serveBuild.timestamp). To rebuild, click \(anchor(to: "/rebuild", displaying: "here"))."
                }
            return
                """
                    <header style="
                        background-color: LightGray;
                        color: #3C3836;
                        text-align: center;
                        padding: 15px 0;
                        margin: 0 0 20px;
                        font-style: oblique;
                        box-sizing: border-box;
                    ">\(bannerMsg)</header>
                """
        }
    }
}
