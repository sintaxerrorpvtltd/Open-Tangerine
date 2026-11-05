import AppKit
import Foundation
import Network
import SwiftUI

// Each editor window owns a read-only session bound to IPv4 loopback. Nothing here can
// accept uploads, write to the original, enumerate directories, or serve arbitrary paths.
final class PDFEditorSession {
    private let queue = DispatchQueue(label: "OpenTangerine.PDFEditor")
    private let listener: NWListener
    private let token = UUID().uuidString
    private let assets: URL
    private let document: Data
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    init(source: URL, assets: URL) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024 else {
            throw OpenTangerineError.invalidInput("Choose a PDF up to 128 MB for editing.")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        document = try handle.read(upToCount: 128 * 1024 * 1024 + 1) ?? Data()
        guard document.count == size, document.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else {
            throw OpenTangerineError.invalidInput("This file is not a readable PDF.")
        }
        self.assets = assets
        guard FileManager.default.fileExists(atPath: assets.appendingPathComponent("web/viewer.html").path) else {
            throw OpenTangerineError.invalidInput("The PDF editor is missing. Reinstall the complete app.")
        }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start(_ completion: @escaping (Result<URL, Error>) -> Void) {
        var delivered = false
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, !delivered else { return }
            switch state {
            case .ready:
                guard let port = self.listener.port else { return }
                let address = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/web/viewer.html?file=../document.pdf")!
                delivered = true
                completion(.success(address))
            case .failed(let error): delivered = true; completion(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped, self.clients.count < 48 else { connection.cancel(); return }
            let id = ObjectIdentifier(connection)
            self.clients[id] = connection
            connection.stateUpdateHandler = { [weak self] state in
                switch state { case .cancelled, .failed: self?.clients.removeValue(forKey: id); default: break }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + 30) { [weak connection] in connection?.cancel() }
            self.receive(connection, Data())
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.async {
            self.stopped = true
            self.listener.cancel()
            self.clients.values.forEach { $0.cancel() }
        }
    }
    private func receive(_ connection: NWConnection, _ prior: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self, let bytes, error == nil else { connection.cancel(); return }
            let data = prior + bytes
            guard data.count <= 16384 else { connection.cancel(); return }
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
                if done { connection.cancel() } else { self.receive(connection, data) }
                return
            }
            let headers = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let first = (headers.first ?? "").components(separatedBy: " ")
            let hosts = headers.dropFirst().filter { $0.lowercased().hasPrefix("host:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            guard first.count == 3, first[0] == "GET", let port = self.listener.port,
                  hosts == ["127.0.0.1:\(port.rawValue)"],
                  let result = self.resource(first[1]) else {
                self.send(connection, status: "404 Not Found", type: "text/plain", data: Data()); return
            }
            self.send(connection, status: "200 OK", type: result.0, data: result.1)
        }
    }
    private func resource(_ request: String) -> (String, Data)? {
        let path = String(request.prefix { $0 != "?" })
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        if relative == "document.pdf" { return ("application/pdf", document) }
        let parts = relative.components(separatedBy: "/")
        guard parts.first == "build" || parts.first == "web",
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0) } }) else { return nil }
        let url = assets.appendingPathComponent(relative)
        let types = ["html":"text/html", "mjs":"text/javascript", "js":"text/javascript", "css":"text/css", "svg":"image/svg+xml", "json":"application/json", "wasm":"application/wasm", "ftl":"text/plain", "png":"image/png"]
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (types[url.pathExtension] ?? "application/octet-stream", data)
    }
    private func send(_ connection: NWConnection, status: String, type: String, data: Data) {
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { error in
            guard error == nil else { connection.cancel(); return }
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        })
    }
}

struct PDFEditorToolView: View {
    let session: ToolSession
    @State private var server: PDFEditorSession?
    @State private var address: URL?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Edit PDF", systemImage: "pencil.and.outline").font(.largeTitle.bold())
            Text(session.primary.lastPathComponent).font(.headline)
            Text("Add text, highlight or draw in the editor. Use its Save button to download an edited copy. Keep this window open until you save.")
            Text("For page order, rotation or removal, choose Organize on the wheel. To add another document, choose Merge.").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            else if let address { Button("Open editor in browser") { NSWorkspace.shared.open(address) } }
            else { ProgressView("Opening local editor…") }
        }.padding(32)
        .task {
            do {
                guard let root = Bundle.main.resourceURL else { throw OpenTangerineError.invalidInput("Missing app resources.") }
                let source = session.primary
                let created = try await Task.detached { try PDFEditorSession(source: source, assets: root.appendingPathComponent("PDFEditor")) }.value
                guard !Task.isCancelled else { created.stop(); return }
                server = created
                created.start { result in DispatchQueue.main.async {
                    switch result {
                    case .success(let url): address = url; _ = NSWorkspace.shared.open(url)
                    case .failure(let problem): error = problem.localizedDescription
                    }
                } }
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { server?.stop(); server = nil }
    }
}
