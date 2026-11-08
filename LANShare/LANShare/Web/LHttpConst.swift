import Foundation

/// HTTP 常量 (HttpServer: HttpConstant.java)
enum LHttpConstant {
    static let contentLength = "Content-Length"
    static let contentType = "Content-Type"
    static let acceptRanges = "Accept-Ranges"
    static let contentRange = "Content-Range"
    static let connection = "Connection"
    static let acceptEncoding = "accept-encoding"
    static let transferEncoding = "transfer-encoding"
    static let keepAlive = "keep-alive"
    static let referer = "referer"
    static let protocolSplit = "://"
    static let close = "close"
    static let contentDisposition = "Content-Disposition"
    static let xRealIP = "X-Real-IP"
    static let xForwardedFor = "X-Forwarded-For"
    static let methodGet = "GET"
    static let methodPost = "POST"
    static let methodPut = "PUT"
    static let unknown = "unknown"
    static let httpVersion = "HTTP/1.1"
    static let htmlContentType = "text/html; charset-utf-8"
    static let textContentType = "text/plain; charset=UTF-8"
    static let streamContentType = "application/octet-stream"
    static let streamContextImage = "image/png"
    static let streamContextJson = "application/json"
    static let wsMagic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    static let crlf = "\r\n"
}

/// HTTP 状态码 (HttpServer: StatusEnum.java)
enum LHttpStatus {
    case ok, movedPermanently, found, noContent, notFound, methodNotAllowed, internalServerError

    var code: Int32 {
        switch self {
        case .ok: return 200
        case .movedPermanently: return 301
        case .found: return 302
        case .noContent: return 204
        case .notFound: return 404
        case .methodNotAllowed: return 405
        case .internalServerError: return 500
        }
    }

    var message: String {
        switch self {
        case .ok: return "OK"
        case .movedPermanently: return "Moved Permanently"
        case .found: return "Found"
        case .noContent: return "No Content"
        case .notFound: return "Not Found"
        case .methodNotAllowed: return "Method Not Allowed"
        case .internalServerError: return "Internal Server Error"
        }
    }
}

/// 头部/参数大小写无关映射 (HttpServer: utils/CaseInsensitiveMap.java)
struct LCaseInsensitiveMap {
    private var storage: [String: String] = [:]
    private var order: [(key: String, name: String)] = []

    mutating func put(_ name: String, _ value: String) {
        let k = name.lowercased()
        if storage[k] == nil {
            order.append((k, name))
        } else if let idx = order.firstIndex(where: { $0.0 == k }) {
            order[idx] = (k, name)
        }
        storage[k] = value
    }

    func get(_ name: String) -> String? { storage[name.lowercased()] }

    func contains(_ name: String) -> Bool { storage[name.lowercased()] != nil }

    /// 与 Java TreeMap(CASE_INSENSITIVE_ORDER) 一致：按键名排序输出
    var sortedEntries: [(name: String, value: String)] {
        order.sorted { $0.0 < $1.0 }.map { (storage[$0.0] == nil ? ($0.1, "") : ($0.1, storage[$0.0]!)) }
    }
}

/// URL 拆解 (HttpServer: Url.java)
final class LUrl {
    var protocolName: String = ""
    var host: String = ""
    var port: Int = 0
    var path: String = ""
    var url: String = ""
    var query: String?

    /// 对应 HttpUtil.parseHttpUrl：兼容 IPv6 方括号写法
    static func parse(_ text: String?) -> LUrl? {
        guard let text, !text.isEmpty, text.contains(LHttpConstant.protocolSplit) else { return nil }
        let obj = LUrl()
        let protocolName = String(text.prefix(while: { $0 != ":" }))
        let remaining = String(text.dropFirst(protocolName.count + 3))
        var slashIndex = remaining.count
        if let idx = remaining.firstIndex(of: "/") {
            slashIndex = remaining.distance(from: remaining.startIndex, to: idx)
        }
        let hostPort = String(remaining.prefix(slashIndex))
        var host = hostPort
        var port = (protocolName == "ws" || protocolName == "http") ? 80 : 443
        if let bracket = hostPort.lastIndex(of: "]") {
            let end = hostPort.distance(from: hostPort.startIndex, to: bracket) + 1
            host = String(hostPort.prefix(end))
            if let colon = hostPort.lastIndex(of: ":"),
               hostPort.distance(from: hostPort.startIndex, to: colon) >= end {
                port = Int(hostPort.suffix(from: hostPort.index(after: colon))) ?? port
            }
        } else if let colon = hostPort.firstIndex(of: ":") {
            host = String(hostPort.prefix(upTo: colon))
            port = Int(hostPort.suffix(from: hostPort.index(after: colon))) ?? port
        }
        let path = slashIndex < remaining.count ? String(remaining.dropFirst(slashIndex)) : "/"
        obj.protocolName = protocolName
        obj.host = host
        obj.port = port
        obj.path = path
        obj.url = text
        if let q = text.firstIndex(of: "?") {
            obj.query = String(text[text.index(after: q)...])
        }
        return obj
    }
}

/// URL 百分号解码 (Java URLDecoder.decode(s, "UTF-8")：'+' 也视为空格)
enum LUrlCoding {
    static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    static func decode(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "+") {
                out.append(UInt8(ascii: " "))
                i += 1
            } else if b == UInt8(ascii: "%"), i + 2 < bytes.count,
                      let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(UInt8(hi << 4 | lo))
                i += 3
            } else {
                out.append(b)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func encode(_ text: String) -> String {
        var result = ""
        for byte in Array(text.utf8) {
            let scalar = UnicodeScalar(byte)
            if allowed.contains(scalar) {
                result.append(Character(scalar))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(b - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(b - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(b - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }
}
