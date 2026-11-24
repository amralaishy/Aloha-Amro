import Foundation
import Network

/// Tiny HTTP server: lists Downloads, serves files (streamed), accepts PUT uploads.
final class WifiServer: ObservableObject {
    static let shared = WifiServer()
    @Published var running = false
    @Published var address: String?
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080

    func start() {
        guard listener == nil, let l = try? NWListener(using: .tcp, on: port) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: .global())
        listener = l
        DispatchQueue.main.async { self.running = true; self.address = self.ip().map { "http://\($0):8080" } }
    }

    func stop() {
        listener?.cancel(); listener = nil
        running = false; address = nil
    }

    private func ip() -> String? {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0 else { return nil }
        defer { freeifaddrs(ifa) }
        var p = ifa
        while let i = p {
            if i.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET), String(cString: i.pointee.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(i.pointee.ifa_addr, socklen_t(i.pointee.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            p = i.pointee.ifa_next
        }
        return nil
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global())
        readHeader(c, Data())
    }

    private func readHeader(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let r = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<r.lowerBound], as: UTF8.self)
                let rest = Data(b[r.upperBound...])
                self.route(c, head, rest)
            } else if err == nil && !done { self.readHeader(c, b) } else { c.cancel() }
        }
    }

    private func respond(_ c: NWConnection, _ status: String, _ type: String, _ body: Data) {
        let h = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(_ c: NWConnection, _ head: String, _ rest: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { c.cancel(); return }
        let method = String(parts[0])
        let path = String(parts[1]).removingPercentEncoding ?? String(parts[1])
        let dir = Paths.downloads

        if method == "GET", path == "/" {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let rows = files.sorted().map { f -> String in
                let e = f.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? f
                return "<li><a href='/f/\(e)'>\(f)</a></li>"
            }.joined()
            let html = """
            <html><meta name=viewport content='width=device-width'><body style='font-family:sans-serif'>
            <h2>Downloads</h2><ul>\(rows)</ul><h3>Upload</h3>
            <input type=file id=f multiple><button onclick="up()">Upload</button><p id=s></p>
            <script>async function up(){for(const x of document.getElementById('f').files){
            document.getElementById('s').textContent='Uploading '+x.name+'…';
            await fetch('/u/'+encodeURIComponent(x.name),{method:'PUT',body:x});}
            location.reload();}</script></body></html>
            """
            respond(c, "200 OK", "text/html; charset=utf-8", Data(html.utf8))
        } else if method == "GET", path.hasPrefix("/f/") {
            let name = String(path.dropFirst(3)).replacingOccurrences(of: "/", with: "")
            let url = dir.appendingPathComponent(name)
            guard let fh = try? FileHandle(forReadingFrom: url),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
                respond(c, "404 Not Found", "text/plain", Data("Not found".utf8)); return
            }
            let h = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\nContent-Disposition: attachment; filename=\"\(name)\"\r\nConnection: close\r\n\r\n"
            c.send(content: Data(h.utf8), completion: .contentProcessed { _ in self.stream(c, fh) })
        } else if method == "PUT", path.hasPrefix("/u/") {
            let name = String(path.dropFirst(3)).replacingOccurrences(of: "/", with: "")
            let len = lines.first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            let dest = DownloadManager.shared.uniqueURL(dir, name)
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            guard let fh = try? FileHandle(forWritingTo: dest) else { c.cancel(); return }
            fh.write(rest)
            receiveBody(c, fh, len - rest.count)
        } else {
            respond(c, "404 Not Found", "text/plain", Data("Not found".utf8))
        }
    }

    private func stream(_ c: NWConnection, _ fh: FileHandle) {
        let chunk = fh.readData(ofLength: 256 * 1024)
        if chunk.isEmpty { try? fh.close(); c.cancel(); return }
        c.send(content: chunk, completion: .contentProcessed { [weak self] e in
            if e != nil { c.cancel() } else { self?.stream(c, fh) }
        })
    }

    private func receiveBody(_ c: NWConnection, _ fh: FileHandle, _ remaining: Int) {
        if remaining <= 0 {
            try? fh.close()
            respond(c, "200 OK", "text/plain", Data("ok".utf8)); return
        }
        c.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 256 * 1024)) { [weak self] d, _, done, err in
            if let d { fh.write(d) }
            if err != nil || (done && d == nil) { try? fh.close(); c.cancel(); return }
            self?.receiveBody(c, fh, remaining - (d?.count ?? 0))
        }
    }
}
