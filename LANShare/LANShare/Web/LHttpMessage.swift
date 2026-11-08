import Foundation

/// 请求 (HttpServer: HttpBase.java + Request.java)
final class LHttpRequest {
    let socket: LHttpSocket

    private var headers = LCaseInsensitiveMap()
    private var contentLengthValue: Int64 = 0
    private var clientIp: String
    private(set) var refererUrl: LUrl?

    let url = LUrl()
    /// 查询参数：保持插入顺序，等价 LinkedHashMap
    private var queryParams: [(key: String, value: String?)] = []
    private(set) var requestMethod: String = ""

    init(_ socket: LHttpSocket) {
        self.socket = socket
        clientIp = socket.remoteIP
        url.host = socket.remoteIP
        url.port = socket.remotePort
    }

    // MARK: - 头部

    func addHeader(_ key: String, _ value: String) {
        headers.put(key, value)
        if key.caseInsensitiveCompare(LHttpConstant.contentLength) == .orderedSame {
            let cleaned = value.replacingOccurrences(of: "[\\s+\\t\\n\\r]", with: "", options: .regularExpression)
            contentLengthValue = Int64(cleaned) ?? 0
        } else if key.caseInsensitiveCompare(LHttpConstant.referer) == .orderedSame {
            refererUrl = LUrl.parse(value)
        }
    }

    func getHeaderValue(_ key: String) -> String? { headers.get(key) }

    var headerEntries: [(name: String, value: String)] { headers.sortedEntries }

    var contentLength: Int64 { contentLengthValue }

    func setContentLength(_ length: Int64) {
        contentLengthValue = length
        headers.put(LHttpConstant.contentLength, String(length))
    }

    var isClosed: Bool { socket.isClosed }

    func setClientIp(_ ip: String) { clientIp = ip }

    /// 对应 getRealClientIP()：优先 nginx 转发头
    var realClientIP: String {
        if let ip = headers.get(LHttpConstant.xRealIP), !ip.isEmpty, ip != LHttpConstant.unknown {
            return ip
        }
        if let ip = headers.get(LHttpConstant.xForwardedFor), !ip.isEmpty, ip != LHttpConstant.unknown {
            return ip
        }
        return clientIp
    }

    var clientIP: String { clientIp }

    // MARK: - 路径与参数

    var requestFullPath: String { url.url }

    func setRequestFullPath(_ value: String) { url.url = value }

    var requestPath: String { url.path }

    func setRequestPath(_ value: String) { url.path = value }

    var requestQueryParams: String? { url.query }

    func setRequestQueryParams(_ value: String?) { url.query = value }

    func setRequestMethod(_ method: String) { requestMethod = method.uppercased() }

    func addPathParams(_ key: String, _ value: String?) {
        if let idx = queryParams.firstIndex(where: { $0.key == key }) {
            queryParams[idx] = (key, value)
        } else {
            queryParams.append((key, value))
        }
    }

    func getQueryParam(_ key: String) -> String? {
        queryParams.first(where: { $0.key == key })?.value
    }

    var allQueryParams: [(key: String, value: String?)] { queryParams }

    /// 对应 genQueryParam()
    func genQueryParam() -> String? {
        guard !queryParams.isEmpty else { return nil }
        var text = ""
        for entry in queryParams {
            if entry.value == nil || entry.value!.isEmpty {
                text += entry.key + "&"
            } else {
                text += entry.key + "=" + entry.value! + "&"
            }
        }
        return String(text.dropLast())
    }

    func genFullRequestPath() -> String {
        guard let query = genQueryParam() else { return url.path }
        return url.path + "?" + query
    }

    // MARK: - 请求体

    /// 对应 getBodyInputStream()
    func getBodyInputStream() -> LBodyInputStream? {
        let size = Int(contentLength)
        if size == 0 { return nil }
        return LBodyInputStream(socket, size: size)
    }

    /// 对应 getRequestBody()
    func getRequestBody() -> String? {
        guard let body = getBodyInputStream() else { return nil }
        return body.readAllText()
    }

    func getSingleUploadInputStream() -> LSingleUploadInputStream? {
        LSingleUploadInputStream(request: self)
    }

    func getMultUploadInputStream() -> LMultUploadInputStream? {
        LMultUploadInputStream(request: self)
    }

    /// 对应 transferUploadFile(path)
    func transferUploadFile(toDirectory path: String) -> LUploadResult? {
        guard let single = getSingleUploadInputStream() else { return nil }
        return single.save(toDirectory: path)
    }

    /// 对应 getRangeLength()：[start, end]，end 为 -1 表示直到文件尾
    func getRangeLength() -> (start: Int64, end: Int64)? {
        guard let rangeHeader = getHeaderValue("Range"), !rangeHeader.isEmpty else { return nil }
        let prefix = "bytes="
        guard rangeHeader.hasPrefix(prefix) else { return nil }
        let values = String(rangeHeader.dropFirst(prefix.count)).split(separator: "-")
        var start: Int64 = 0
        var end: Int64 = -1
        if let first = values.first { start = Int64(first) ?? 0 }
        if values.count >= 2 { end = Int64(values[1]) ?? -1 }
        return (start, end)
    }
}

/// 响应 (HttpServer: Response.java)
final class LHttpResponse {
    let socket: LHttpSocket

    private var headers = LCaseInsensitiveMap()
    private var contentLengthValue: Int64 = 0
    private var status: Int32 = 200
    private var statusMessage = "OK"
    private(set) var isResponded = false
    var rangeLength: (start: Int64, end: Int64)?

    init(_ socket: LHttpSocket) {
        self.socket = socket
        setStatus(200, "OK")
        addHeader(LHttpConstant.contentType, LHttpConstant.htmlContentType)
        addHeader(LHttpConstant.connection, LHttpConstant.close)
    }

    // MARK: - 头部

    func addHeader(_ key: String, _ value: String) {
        headers.put(key, value)
        if key.caseInsensitiveCompare(LHttpConstant.contentLength) == .orderedSame {
            let cleaned = value.replacingOccurrences(of: "[\\s+\\t\\n\\r]", with: "", options: .regularExpression)
            contentLengthValue = Int64(cleaned) ?? 0
        }
    }

    func getHeaderValue(_ key: String) -> String? { headers.get(key) }

    var contentLength: Int64 { contentLengthValue }

    func setContentLength(_ length: Int64) {
        contentLengthValue = length
        headers.put(LHttpConstant.contentLength, String(length))
    }

    func setContentType(_ contentType: String) {
        addHeader(LHttpConstant.contentType, contentType)
    }

    func setStatus(_ code: Int32, _ message: String) {
        status = code
        statusMessage = message
    }

    var isClosed: Bool { socket.isClosed }

    /// 对应 setContentRange
    func setContentRange(start: Int64, end: Int64, length: Int64) {
        setStatus(206, "Partial Content")
        addHeader(LHttpConstant.acceptRanges, "bytes")
        addHeader(LHttpConstant.contentRange,
                  "bytes \(start)-\(end - 1)/\(length + start)")
        setContentLength(length)
    }

    /// 对应 createHeader()
    private func createHeader() -> String {
        var text = "\(LHttpConstant.httpVersion) \(status) \(statusMessage)\(LHttpConstant.crlf)"
        for entry in headers.sortedEntries {
            text += entry.name + ": " + entry.value + LHttpConstant.crlf
        }
        text += LHttpConstant.crlf
        return text
    }

    // MARK: - 写出

    func writeBytes(_ bytes: [UInt8], contentType: String) throws {
        guard !isClosed else { return }
        setContentLength(Int64(bytes.count))
        setContentType(contentType)
        try socket.write(createHeader())
        if !bytes.isEmpty { try socket.write(bytes) }
        isResponded = true
    }

    func writeBytes(_ bytes: [UInt8]) throws {
        try writeBytes(bytes, contentType: LHttpConstant.streamContentType)
    }

    /// 对应 writeString(String)：默认 JSON
    func writeString(_ body: String) throws {
        try writeString(body, contentType: LHttpConstant.streamContextJson)
    }

    func writeString(_ body: String, contentType: String) throws {
        try writeBytes(Array(body.utf8), contentType: contentType)
    }

    func writeEmpty() throws {
        try writeString("", contentType: LHttpConstant.streamContextJson)
    }

    func writeErrorCode(_ state: LHttpStatus, message: String) throws {
        try writeErrorCode(state.code, message: message)
    }

    func writeErrorCode(_ state: LHttpStatus) throws {
        try writeErrorCode(state, message: state.message)
    }

    /// 对应 writeErrorCode(int, String)：状态消息取错误文本
    func writeErrorCode(_ code: Int32, message: String) throws {
        setStatus(code, message)
        try writeBytes(Array(message.utf8), contentType: LHttpConstant.textContentType)
    }

    func write204() throws {
        try writeErrorCode(.noContent, message: "204 No Content")
    }

    func write404() throws {
        try write404(message: "404 Not Found")
    }

    func write404(message: String) throws {
        try writeErrorCode(.notFound, message: message)
    }

    func write405() throws {
        try write405(message: "405 Method Not Allowed")
    }

    func write405(message: String) throws {
        try writeErrorCode(.methodNotAllowed, message: message)
    }

    func write500() throws {
        try writeErrorCode(.internalServerError, message: "500 error")
    }

    func write500(message: String) throws {
        try writeErrorCode(.internalServerError, message: message)
    }

    /// 对应 write302(message, url)
    func write302(message: String, url: String) throws {
        addHeader("Location", url)
        try writeErrorCode(.found, message: message)
    }

    /// 对应 getContentTypeByName
    static func getContentTypeByName(_ name: String) -> String? {
        LContentTypes.contentType(forName: name)
    }

    /// 对应 writeFile(File)
    func writeFile(_ path: String) throws {
        let name = (path as NSString).lastPathComponent
        let contentType = LHttpResponse.getContentTypeByName(name) ?? LHttpConstant.streamContentType
        try writeFile(path, contentType: contentType)
    }

    /// 对应 writeFile(File, contentType)
    func writeFile(_ path: String, contentType: String) throws {
        guard !isClosed else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let length = (attrs[.size] as? NSNumber)?.int64Value, length > 0 else {
            try write404()
            return
        }
        guard let reader = try? LFileReader(path: path) else {
            try write404()
            return
        }
        defer { reader.close() }

        setContentLength(length)
        setContentType(contentType)
        if rangeLength == nil {
            setStatus(200, "OK")
            try socket.write(createHeader())
            setContentLength(length)
            _ = LHttpIO.transfer(reader, socket)
        } else {
            let start = rangeLength!.start
            var end = rangeLength!.end
            if end == -1 { end = length }
            let contentLength = length - start
            setContentRange(start: start, end: end, length: contentLength)
            try socket.write(createHeader())
            try? reader.skip(to: start)
            _ = LHttpIO.transfer(reader, socket, size: contentLength)
        }
        isResponded = true
    }

    func writeStream(_ source: LStreamSource) throws {
        try writeStream(source, contentType: LHttpConstant.streamContentType)
    }

    /// 对应 writeStream(is, contentType)
    func writeStream(_ source: LStreamSource, contentType: String) throws {
        guard !isClosed else { return }
        setContentType(contentType)
        try writeDirectStream(source)
    }

    /// 对应 writeDirectStream：无 Content-Length，靠关闭连接结束
    func writeDirectStream(_ source: LStreamSource) throws {
        guard !isClosed else { return }
        try socket.write(createHeader())
        _ = LHttpIO.transfer(source, socket)
        close()
        isResponded = true
    }

    /// 对应 getBodyOutputStream(contentType)
    func getBodyOutputStream(contentType: String) throws -> LHttpSocket {
        setContentType(contentType)
        try socket.write(createHeader())
        isResponded = true
        return socket
    }

    func close() {
        socket.close()
    }
}

extension LFileReader: LStreamSource {}
