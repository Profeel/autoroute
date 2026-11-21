import Darwin
import Foundation

public struct HTTPRequestMessage: Sendable {
    public var method: String
    public var path: String
    public var query: String
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? {
        let target = name.lowercased()
        for (k, v) in headers where k.lowercased() == target {
            return v
        }
        return nil
    }
}

public enum LoopbackServerError: Error, LocalizedError, Equatable, Sendable {
    case invalidPort(Int)
    case portInUse(Int)
    case socketCreationFailed(Int32)
    case bindFailed(Int, Int32)
    case listenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "端口号 \(port) 无效，请填写 1024 到 65535 之间的端口"
        case .portInUse(let port):
            return "本地端口 127.0.0.1:\(port) 已被其他程序占用"
        case .socketCreationFailed(let code):
            return "无法创建本地监听 Socket (errno=\(code))"
        case .bindFailed(let port, let code):
            return "绑定 127.0.0.1:\(port) 失败 (errno=\(code))"
        case .listenFailed(let code):
            return "监听本地端口失败 (errno=\(code))"
        }
    }
}

public final class HTTPConnectionWriter: @unchecked Sendable {
    private let fd: Int32
    private let keepAlive: Bool
    private let lock = NSLock()
    private var headersSent = false
    private var isClosed = false
    private var isChunked = false

    init(fd: Int32, keepAlive: Bool = false) {
        self.fd = fd
        self.keepAlive = keepAlive
    }

    var didClose: Bool {
        lock.withLock { isClosed }
    }

    var didSendResponse: Bool {
        lock.withLock { headersSent }
    }

    public func sendJSON(statusCode: Int, headers: [String: String] = [:], body: Data) {
        var allHeaders = headers
        allHeaders["Content-Type"] = allHeaders["Content-Type"] ?? "application/json; charset=utf-8"
        allHeaders["Content-Length"] = "\(body.count)"
        let shouldKeepAlive = keepAlive && allHeaders["Connection"]?.lowercased() != "close"
        if shouldKeepAlive {
            allHeaders["Connection"] = "keep-alive"
            allHeaders["Keep-Alive"] = "timeout=15, max=100"
        } else {
            allHeaders["Connection"] = "close"
        }
        let headerOK = sendRawHeaders(statusCode: statusCode, headers: allHeaders, trailingBody: body)
        if !shouldKeepAlive || !headerOK {
            close()
        }
    }

    @discardableResult
    public func startChunkedStream(statusCode: Int = 200, headers: [String: String] = [:]) -> Bool {
        var allHeaders = headers
        allHeaders["Content-Type"] = "text/event-stream; charset=utf-8"
        allHeaders["Cache-Control"] = "no-cache"
        allHeaders["X-Accel-Buffering"] = "no"
        allHeaders["Transfer-Encoding"] = "chunked"
        allHeaders["Connection"] = "close"
        isChunked = true
        let sent = sendRawHeaders(statusCode: statusCode, headers: allHeaders)
        if !sent { close() }
        return sent
    }

    public func writeStreamChunk(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        lock.lock()
        let active = !isClosed
        let chunked = isChunked
        lock.unlock()
        guard active else { return false }

        if chunked {
            let prefix = Data((String(data.count, radix: 16) + "\r\n").utf8)
            let suffix = Data("\r\n".utf8)
            var frame = Data(capacity: prefix.count + data.count + suffix.count)
            frame.append(prefix)
            frame.append(data)
            frame.append(suffix)
            return writeBytes(frame)
        } else {
            return writeBytes(data)
        }
    }

    public func finishStream() {
        lock.lock()
        let shouldSendEnd = !isClosed && isChunked
        lock.unlock()
        if shouldSendEnd {
            _ = writeBytes(Data("0\r\n\r\n".utf8))
        }
        close()
    }

    public func close() {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        lock.unlock()
        if !alreadyClosed {
            Darwin.close(fd)
        }
    }

    @discardableResult
    private func sendRawHeaders(statusCode: Int, headers: [String: String], trailingBody: Data? = nil) -> Bool {
        lock.lock()
        if headersSent || isClosed {
            lock.unlock()
            return false
        }
        headersSent = true
        lock.unlock()

        var lines: [String] = ["HTTP/1.1 \(statusCode) \(reasonPhrase(for: statusCode))"]
        for (k, v) in headers {
            lines.append("\(k): \(v)")
        }
        lines.append("")
        lines.append("")
        let raw = lines.joined(separator: "\r\n")
        if let trailingBody, !trailingBody.isEmpty {
            var packet = Data(capacity: raw.utf8.count + trailingBody.count)
            packet.append(contentsOf: raw.utf8)
            packet.append(trailingBody)
            return writeBytes(packet)
        }
        return writeBytes(Data(raw.utf8))
    }

    @discardableResult
    private func writeBytes(_ data: Data) -> Bool {
        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let basePtr = rawBuffer.baseAddress else { return true }
            var totalSent = 0
            while totalSent < data.count {
                let remaining = data.count - totalSent
                let sent = Darwin.send(fd, basePtr.advanced(by: totalSent), remaining, 0)
                if sent <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                totalSent += sent
            }
            return true
        }
    }

    private func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }
}

/// Strictly 127.0.0.1 loopback HTTP/1.1 server built on POSIX sockets.
public final class LoopbackHTTPServer: @unchecked Sendable {
    public typealias RequestHandler = @Sendable (HTTPRequestMessage, HTTPConnectionWriter) async -> Void

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var runningPort: Int?
    private var acceptSource: DispatchSourceRead?
    private var activeClientFDs: Set<Int32> = []
    private let acceptQueue = DispatchQueue(label: "org.automodel.http.accept", qos: .userInitiated)
    private let requestHandler: RequestHandler

    public init(handler: @escaping RequestHandler) {
        signal(SIGPIPE, SIG_IGN)
        self.requestHandler = handler
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        stateLock.withLock { listenFD >= 0 }
    }

    public var currentPort: Int? {
        stateLock.withLock { runningPort }
    }

    /// Starts listening strictly on 127.0.0.1:<port>.
    /// If port == 0, the OS assigns an ephemeral free port on 127.0.0.1.
    @discardableResult
    public func start(port: Int) throws -> Int {
        if port != 0 && (port < 1024 || port > 65535) {
            throw LoopbackServerError.invalidPort(port)
        }

        stop()

        if port != 0 && Self.isLoopbackPortOccupied(port) {
            throw LoopbackServerError.portInUse(port)
        }

        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            throw LoopbackServerError.socketCreationFailed(errno)
        }

        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if bindResult != 0 {
            let err = errno
            Darwin.close(fd)
            if err == EADDRINUSE {
                throw LoopbackServerError.portInUse(port)
            }
            throw LoopbackServerError.bindFailed(port, err)
        }

        if Darwin.listen(fd, 128) != 0 {
            let err = errno
            Darwin.close(fd)
            throw LoopbackServerError.listenFailed(err)
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolvedPort: Int
        let getsockRes = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(fd, sockPtr, &boundLen)
            }
        }
        if getsockRes == 0 {
            resolvedPort = Int(UInt16(bigEndian: boundAddr.sin_port))
        } else {
            resolvedPort = port
        }

        // Non-blocking listen socket monitored by DispatchSource
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingConnections(listenFD: fd)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }

        stateLock.withLock {
            self.listenFD = fd
            self.runningPort = resolvedPort
            self.acceptSource = source
        }

        source.resume()
        return resolvedPort
    }

    public func stop() {
        let (sourceToCancel, fdsToShutdown): (DispatchSourceRead?, [Int32]) = stateLock.withLock {
            let src = acceptSource
            acceptSource = nil
            listenFD = -1
            runningPort = nil
            let fds = Array(activeClientFDs)
            activeClientFDs.removeAll()
            return (src, fds)
        }
        sourceToCancel?.cancel()
        for clientFD in fdsToShutdown {
            _ = Darwin.shutdown(clientFD, SHUT_RDWR)
        }
    }

    public static func isLoopbackPortOccupied(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }

    public static func findAvailablePort(startingFrom startPort: Int, maxAttempts: Int = 50) -> Int? {
        let base = max(1024, min(65000, startPort))
        for offset in 0..<maxAttempts {
            let candidate = base + offset
            if !isLoopbackPortOccupied(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func acceptPendingConnections(listenFD: Int32) {
        while true {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.accept(listenFD, sockPtr, &addrLen)
                }
            }
            if clientFD < 0 {
                if errno == EWOULDBLOCK || errno == EAGAIN {
                    break
                }
                break
            }

            // Ensure blocking reads on client socket with SO_NOSIGPIPE
            let flags = fcntl(clientFD, F_GETFL, 0)
            _ = fcntl(clientFD, F_SETFL, flags & ~O_NONBLOCK)
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            let handler = self.requestHandler
            stateLock.withLock { _ = activeClientFDs.insert(clientFD) }
            Task.detached(priority: .userInitiated) { [weak self] in
                await Self.handleClientSocket(
                    fd: clientFD,
                    handler: handler,
                    onBeforeClose: { [weak self] closedFD in
                        self?.stateLock.withLock { _ = self?.activeClientFDs.remove(closedFD) }
                    }
                )
            }
        }
    }

    private enum HTTPReadResult {
        case request(HTTPRequestMessage, keepAlive: Bool)
        case eof
        case malformed
    }

    private static func handleClientSocket(
        fd: Int32,
        handler: @escaping RequestHandler,
        onBeforeClose: @escaping @Sendable (Int32) -> Void
    ) async {
        var carryOver = Data()
        let maxRequestsPerConnection = 100
        var handledCount = 0

        while handledCount < maxRequestsPerConnection {
            let readResult = readHTTPRequest(fd: fd, carryOver: &carryOver)
            switch readResult {
            case .eof:
                onBeforeClose(fd)
                Darwin.close(fd)
                return
            case .malformed:
                let writer = HTTPConnectionWriter(fd: fd, keepAlive: false)
                onBeforeClose(fd)
                writer.sendJSON(
                    statusCode: 400,
                    body: Data(#"{"error":{"message":"Malformed HTTP request","type":"invalid_request_error"}}"#.utf8)
                )
                return
            case .request(let req, let clientWantsKeepAlive):
                handledCount += 1
                let allowKeepAlive = clientWantsKeepAlive && handledCount < maxRequestsPerConnection
                let writer = HTTPConnectionWriter(fd: fd, keepAlive: allowKeepAlive)
                await handler(req, writer)
                if writer.didClose {
                    onBeforeClose(fd)
                    return
                }
                if !allowKeepAlive || !writer.didSendResponse {
                    onBeforeClose(fd)
                    writer.close()
                    return
                }
            }
        }
        onBeforeClose(fd)
        Darwin.close(fd)
    }

    private static func readHTTPRequest(fd: Int32, carryOver: inout Data) -> HTTPReadResult {
        var buffer = carryOver
        carryOver.removeAll(keepingCapacity: true)
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let separator = Data("\r\n\r\n".utf8)
        var headerEndRange = buffer.range(of: separator)

        while headerEndRange == nil {
            let n = Darwin.recv(fd, &chunk, chunk.count, 0)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return buffer.isEmpty ? .eof : .malformed
            }
            buffer.append(contentsOf: chunk[0..<n])
            headerEndRange = buffer.range(of: separator)
            if buffer.count > 1_048_576 {
                return .malformed
            }
        }

        guard let headerEnd = headerEndRange else { return .malformed }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .malformed }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return .malformed }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let httpVersion = parts.count >= 3 ? String(parts[2]).uppercased() : "HTTP/1.1"
        let targetComponents = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(targetComponents[0])
        let query = targetComponents.count > 1 ? String(targetComponents[1]) : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        let connectionHeader = headers.first(where: { $0.key.lowercased() == "connection" })?.value.lowercased()
        let keepAlive: Bool
        if httpVersion == "HTTP/1.0" {
            keepAlive = (connectionHeader == "keep-alive")
        } else {
            keepAlive = (connectionHeader != "close")
        }

        var remaining = Data(buffer[headerEnd.upperBound...])
        let contentLengthHeader = headers.first(where: { $0.key.lowercased() == "content-length" })?.value
        let isChunkedRequest = headers.first(where: { $0.key.lowercased() == "transfer-encoding" })?
            .value.lowercased().contains("chunked") == true
        let maxBody = 32 * 1024 * 1024
        var bodyData = Data()

        if isChunkedRequest {
            guard let decoded = readChunkedBody(fd: fd, buffer: &remaining, maxBodyBytes: maxBody) else {
                return .malformed
            }
            bodyData = decoded
            carryOver = remaining.isEmpty ? Data() : Data(remaining)
        } else if let contentLengthStr = contentLengthHeader {
            guard let contentLength = Int(contentLengthStr), contentLength >= 0, contentLength <= maxBody else {
                return .malformed
            }
            while remaining.count < contentLength {
                let n = Darwin.recv(fd, &chunk, chunk.count, 0)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return .malformed
                }
                remaining.append(contentsOf: chunk[0..<n])
            }
            bodyData = Data(remaining.prefix(contentLength))
            if remaining.count > contentLength {
                carryOver = Data(remaining.dropFirst(contentLength))
            }
        } else {
            carryOver = remaining.isEmpty ? Data() : Data(remaining)
        }

        return .request(
            HTTPRequestMessage(
                method: method,
                path: path,
                query: query,
                headers: headers,
                body: bodyData
            ),
            keepAlive: keepAlive
        )
    }

    private static func readChunkedBody(fd: Int32, buffer: inout Data, maxBodyBytes: Int) -> Data? {
        var decoded = Data()
        var recvChunk = [UInt8](repeating: 0, count: 16_384)
        let crlf = Data("\r\n".utf8)

        func fillMore() -> Bool {
            let n = Darwin.recv(fd, &recvChunk, recvChunk.count, 0)
            if n < 0 && errno == EINTR { return fillMore() }
            guard n > 0 else { return false }
            buffer.append(contentsOf: recvChunk[0..<n])
            return true
        }

        while true {
            var lineRange = buffer.range(of: crlf)
            while lineRange == nil {
                if buffer.count > maxBodyBytes + 65_536 { return nil }
                guard fillMore() else { return nil }
                lineRange = buffer.range(of: crlf)
            }
            guard let crlfRange = lineRange else { return nil }
            let sizeLineData = buffer[buffer.startIndex..<crlfRange.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<crlfRange.upperBound)

            guard let sizeLine = String(data: sizeLineData, encoding: .utf8),
                  let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces),
                  let chunkSize = Int(sizeToken, radix: 16),
                  chunkSize >= 0 else {
                return nil
            }

            if chunkSize == 0 {
                // Consume optional trailer headers up to the final CRLF.
                if buffer.starts(with: crlf) {
                    buffer.removeFirst(2)
                    return decoded
                }
                let trailerEnd = Data("\r\n\r\n".utf8)
                var endRange = buffer.range(of: trailerEnd)
                while endRange == nil {
                    if buffer.starts(with: crlf) {
                        buffer.removeFirst(2)
                        return decoded
                    }
                    if buffer.count > 65_536 { return nil }
                    guard fillMore() else { return nil }
                    endRange = buffer.range(of: trailerEnd)
                }
                if let endRange {
                    buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
                }
                return decoded
            }

            guard decoded.count + chunkSize <= maxBodyBytes else { return nil }
            let needed = chunkSize + 2 // chunk payload + trailing CRLF
            while buffer.count < needed {
                guard fillMore() else { return nil }
            }
            decoded.append(buffer.prefix(chunkSize))
            let trailing = buffer[buffer.index(buffer.startIndex, offsetBy: chunkSize)..<buffer.index(buffer.startIndex, offsetBy: needed)]
            guard trailing == crlf else { return nil }
            buffer.removeFirst(needed)
        }
    }
}
