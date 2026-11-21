import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A tiny blocking HTTP/1.1 server on 127.0.0.1 for exercising BrainClient end to end.
/// Each request is answered by `handler(method, path, body)` → (status, json body); requests are recorded.
final class StubBrainServer: @unchecked Sendable {
    struct Request: Sendable { var method: String; var path: String; var body: Data }

    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var _requests: [Request] = []
    private let handler: @Sendable (String, String, Data) -> (Int, String)

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    init(handler: @escaping @Sendable (String, String, Data) -> (Int, String)) throws {
        self.handler = handler
        #if canImport(Glibc)
        let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard sock >= 0 else { throw NSError(domain: "stub", code: 1) }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 16) == 0 else { close(sock); throw NSError(domain: "stub", code: 2) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
        }
        fd = sock
        port = UInt16(bigEndian: addr.sin_port)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    func stop() {
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
    }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Range<Data.Index>?
        var contentLength = 0
        while true {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if headerEnd == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r
                let head = String(decoding: data[..<r.lowerBound], as: UTF8.self)
                for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if let r = headerEnd, data.count - r.upperBound >= contentLength { break }
        }
        guard let r = headerEnd else { return }
        let head = String(decoding: data[..<r.lowerBound], as: UTF8.self)
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = parts.count > 0 ? String(parts[0]) : "?"
        let fullPath = parts.count > 1 ? String(parts[1]) : "/"
        let path = String(fullPath.split(separator: "?").first ?? "")
        let body = data[r.upperBound...]
        lock.lock(); _requests.append(Request(method: method, path: path, body: Data(body))); lock.unlock()
        let (status, json) = handler(method, path, Data(body))
        let payload = Array(json.utf8)
        let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        let bytes = Array(response.utf8) + payload
        _ = bytes.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
    }
}
