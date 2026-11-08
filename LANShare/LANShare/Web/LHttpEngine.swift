import Foundation

/// 路由异常 (HttpServer: exception/L*Exception.java)
enum LWebError: Error {
    /// 自定义状态码 + 消息，对应 LCodeException / L404Exception / L500Exception
    case code(Int32, String)
    /// 对应 L302Exception：消息 + 跳转地址
    case move(String, String)

    static func notFound(_ message: String) -> LWebError { .code(404, message) }
    static func serverError(_ message: String) -> LWebError { .code(500, message) }
    static func redirect(_ url: String) -> LWebError { .move("redirect", url) }
}

/// (HttpServer: HttpHandler.java)
typealias LHttpHandler = (LHttpRequest, LHttpResponse) throws -> Void

/// (HttpServer: RequestFilter.java)
typealias LRequestFilter = (LHttpRequest, LHttpResponse, LHttpHandler) throws -> Void

/// 轻量 HTTP 引擎 (HttpServer: HttpServer.java 的混合模式，Socket 由 LANShare 的 TCP 端口复用)
final class LHttpEngine {
    private struct PathEntry {
        let routePattern: String
        let httpMethod: String?
        let handler: LHttpHandler
    }

    private var requestHandlers: [PathEntry] = []
    private var regexCache: [String: NSRegularExpression] = [:]
    private let gate = NSLock()
    var requestFilter: LRequestFilter?
    /// 对应 socketTimeout，Android 默认 30s
    var socketTimeoutMillis: Int = 30_000

    init() {}

    // MARK: - 路由注册

    func addPath(_ routePattern: String, method: String? = nil, handler: @escaping LHttpHandler) {
        gate.lock()
        requestHandlers.append(PathEntry(routePattern: routePattern, httpMethod: method, handler: handler))
        gate.unlock()
    }

    /// 对应 sortRoutePatterns()：模式越长越先匹配
    func sortRoutePatterns() {
        gate.lock()
        requestHandlers.sort { $0.routePattern.count > $1.routePattern.count }
        gate.unlock()
    }

    // MARK: - 路径匹配 (HttpServer: pathMatches / patternToRegex)

    static func patternToRegex(_ pattern: String) -> String {
        var regex = ""
        let tokens = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for (i, token) in tokens.enumerated() {
            if i > 0 { regex += "/" }
            if token == "**" {
                regex += ".*"
            } else if token == "*" {
                regex += "[^/]+"
            } else if token.hasPrefix(":") {
                regex += "[^/]+"
            } else if !token.isEmpty {
                regex += NSRegularExpression.escapedPattern(for: token)
            }
        }
        regex += "/?"
        return "^" + regex + "$"
    }

    private func regex(for pattern: String) -> NSRegularExpression? {
        gate.lock()
        defer { gate.unlock() }
        if let cached = regexCache[pattern] { return cached }
        let built = try? NSRegularExpression(pattern: Self.patternToRegex(pattern))
        if let built { regexCache[pattern] = built }
        return built
    }

    @discardableResult
    func pathMatches(_ routePattern: String, _ incomingPath: String) -> Bool {
        guard let regex = regex(for: routePattern) else { return false }
        return regex.numberOfMatches(in: incomingPath, range: NSRange(incomingPath.startIndex..., in: incomingPath)) > 0
    }

    // MARK: - 请求解析 (HttpServer: utils/HttpUtil.java)

    /// 对应 parseRequestFromStream：initialDataPrefix 是 TCP 嗅探读到的前 4 字节
    func parseRequest(from socket: LHttpSocket, initialPrefix: String?) -> LHttpRequest? {
        let request = LHttpRequest(socket)
        var lineNum = 0
        while true {
            guard let line = LHttpIO.readLine(socket) else { break }
            if line.isEmpty { break }
            guard parseRequestLine(lineNum: lineNum, line: line, request: request, initialPrefix: initialPrefix) else {
                return nil
            }
            lineNum += 1
        }
        return request
    }

    private func parseRequestLine(lineNum: Int, line: String, request: LHttpRequest,
                                  initialPrefix: String?) -> Bool {
        var text = line
        if lineNum == 0, let initialPrefix {
            text = initialPrefix + text
        }
        guard let space = text.firstIndex(of: " ") else { return false }
        let key = String(text[..<space])
        let value = String(text[text.index(after: space)...])

        if lineNum == 0 {
            let parts = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            guard let url = parts.first else { return false }
            request.setRequestFullPath(url)
            if let question = url.firstIndex(of: "?"),
               url.distance(from: url.startIndex, to: question) > 0 {
                let decodedPath = String(url[..<question])
                request.setRequestPath(LUrlCoding.decode(decodedPath))
                request.setRequestQueryParams(String(url[url.index(after: question)...]))
                let query = request.requestQueryParams ?? ""
                if !query.isEmpty {
                    for p in query.split(separator: "&", omittingEmptySubsequences: false) {
                        let param = String(p)
                        if let eq = param.firstIndex(of: "=") {
                            let name = String(param[..<eq])
                            let raw = String(param[param.index(after: eq)...])
                            request.addPathParams(LUrlCoding.decode(name), LUrlCoding.decode(raw))
                        } else {
                            request.addPathParams(LUrlCoding.decode(param), nil)
                        }
                    }
                }
            } else {
                request.setRequestPath(LUrlCoding.decode(url))
                request.setRequestFullPath(request.requestPath)
            }
            request.setRequestMethod(key)
        } else {
            var headerKey = key
            if let colon = headerKey.firstIndex(of: ":"),
               headerKey.distance(from: headerKey.startIndex, to: colon) > 0 {
                headerKey = String(headerKey[..<colon])
            }
            request.addHeader(headerKey, value)
        }
        return true
    }

    // MARK: - 处理连接 (HttpServer: handleWebClient)

    func handleWebClient(_ stream: LTcpStream, prefix: String?) {
        let socket = LHttpSocket(stream)
        socket.setReadTimeout(seconds: max(1, socketTimeoutMillis / 1000))
        let response = LHttpResponse(socket)
        do {
            if let request = parseRequest(from: socket, initialPrefix: prefix) {
                response.rangeLength = request.getRangeLength()
                try dispatch(request: request, response: response)
            } else {
                try response.write500()
            }
        } catch let error as LWebError {
            switch error {
            case .code(let status, let message): try? response.writeErrorCode(status, message: message)
            case .move(let message, let url): try? response.write302(message: message, url: url)
            }
        } catch let error as LSError {
            switch error {
            case .closed, .timeout: break
            default: try? response.write500()
            }
        } catch {
            try? response.write500()
        }
        gracefulClose(socket)
    }

    private func dispatch(request: LHttpRequest, response: LHttpResponse) throws {
        var pathMatched = false
        let entries: [PathEntry]
        gate.lock()
        entries = requestHandlers
        gate.unlock()
        for entry in entries {
            guard pathMatches(entry.routePattern, request.requestPath) else { continue }
            pathMatched = true
            if let method = entry.httpMethod, !method.isEmpty,
               request.requestMethod.compare(method, options: .caseInsensitive) != .orderedSame {
                try response.write405()
                return
            }
            do {
                if let filter = requestFilter {
                    try filter(request, response, entry.handler)
                } else {
                    try entry.handler(request, response)
                }
                if !response.isResponded {
                    try response.write204()
                }
            } catch let error as LWebError {
                switch error {
                case .code(let status, let message): try response.writeErrorCode(status, message: message)
                case .move(let message, let url): try response.write302(message: message, url: url)
                }
                return
            } catch let error as LSError {
                switch error {
                case .closed, .timeout: break
                default: try response.write500()
                }
                return
            } catch {
                LLog.error("handler error \(request.requestPath): \(error)")
                try response.write500()
                return
            }
            break
        }
        if !pathMatched {
            LLog.debug("404 \(request.requestPath) ip=\(request.realClientIP)")
            try response.write404()
        }
    }

    /// 对应 gracefulClose：半关闭写通道后丢弃残余读数据，最长等 2s
    private func gracefulClose(_ socket: LHttpSocket) {
        guard !socket.isClosed else { return }
        socket.shutdownWrite()
        socket.setReadTimeout(seconds: 2)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard let chunk = socket.read(4096), !chunk.isEmpty else { break }
        }
        socket.close()
    }
}
