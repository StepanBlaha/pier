import Foundation

/// Minimal HTTP/1.x response parsing and HTML scraping used by `Prober`.
struct HTTPResponse {
    var status: Int
    var headers: [String: String]   // lowercased names
    var body: Data

    var contentType: String { headers["content-type"]?.lowercased() ?? "" }

    static func request(path: String, port: UInt16) -> Data {
        Data("GET \(path) HTTP/1.1\r\nHost: localhost:\(port)\r\nUser-Agent: pier\r\nAccept: text/html,*/*\r\nConnection: close\r\n\r\n".utf8)
    }

    static func looksLikeHTTP(_ d: Data) -> Bool { d.starts(with: Array("HTTP/".utf8)) }

    /// Parses status line + headers (+ body, de-chunked best effort). Nil if not HTTP or headers incomplete.
    static func parse(_ data: Data) -> HTTPResponse? {
        guard looksLikeHTTP(data) else { return nil }
        let bytes = [UInt8](data)
        let (headEnd, sepLen): (Int, Int)
        if let i = find(bytes, [13, 10, 13, 10]) { (headEnd, sepLen) = (i, 4) }
        else if let i = find(bytes, [10, 10]) { (headEnd, sepLen) = (i, 2) }
        else { return nil }
        let head = String(decoding: bytes[..<headEnd], as: UTF8.self)
        var lines = head.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return nil }
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Array(bytes[(headEnd + sepLen)...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { body = dechunk(body) }
        return HTTPResponse(status: status, headers: headers, body: Data(body))
    }

    /// Enough of the response has arrived to extract everything we need.
    static func isComplete(_ data: Data) -> Bool {
        if data.count >= 65536 { return true }
        guard looksLikeHTTP(data) else {
            // Non-HTTP: wait for 9 bytes (an h2 frame header) unless it can still become "HTTP/".
            return data.count >= 9 || (data.count >= 5 && !looksLikeHTTP(data))
        }
        guard let r = parse(data) else { return false }
        if r.status / 100 == 3 || r.status == 204 || r.status < 200 { return true }
        let ct = r.contentType
        if !ct.isEmpty && !ct.contains("html") { return true }
        if let len = r.headers["content-length"].flatMap(Int.init), r.body.count >= len { return true }
        let lower = String(decoding: r.body, as: UTF8.self).lowercased()
        return lower.contains("</head") || lower.contains("<body")
    }

    static func isH2Frame(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(9))
        // length(3) type(1) flags(1) stream id(4): SETTINGS(4) or GOAWAY(7) on stream 0.
        return b.count == 9 && b[0] == 0 && (b[3] == 4 || b[3] == 7) && b[5...8].allSatisfy { $0 == 0 }
    }

    static func isTLSRecord(_ d: Data) -> Bool { d.first == 0x15 || d.first == 0x16 }

    // MARK: HTML

    var looksLikeHTML: Bool {
        if contentType.contains("html") { return true }
        guard contentType.isEmpty || contentType.contains("text/plain") else { return false }
        let head = String(decoding: body.prefix(2048), as: UTF8.self).lowercased()
        return head.contains("<!doctype html") || head.contains("<html") || head.contains("<title")
    }

    var html: String { String(decoding: body, as: UTF8.self) }

    static func title(in html: String) -> String? {
        var from = html.startIndex
        while let r = html.range(of: "<title", options: .caseInsensitive, range: from..<html.endIndex) {
            let after = r.upperBound
            guard after < html.endIndex, html[after] == ">" || html[after].isWhitespace else { from = after; continue }
            guard let gt = html.range(of: ">", range: after..<html.endIndex) else { return nil }
            let rest = gt.upperBound..<html.endIndex
            let end = html.range(of: "</title", options: .caseInsensitive, range: rest)?.lowerBound
                ?? html.range(of: "<", range: rest)?.lowerBound
                ?? html.endIndex
            let text = decodeEntities(String(html[gt.upperBound..<end]))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return text.isEmpty ? nil : String(text.prefix(120))
        }
        return nil
    }

    /// Best <link rel=icon> href (raw, unresolved): `icon` / `shortcut icon` preferred over apple-touch-icon.
    static func iconHref(in html: String) -> String? {
        var icon: String?, touch: String?
        var from = html.startIndex
        while let r = html.range(of: "<link", options: .caseInsensitive, range: from..<html.endIndex) {
            guard let gt = html.range(of: ">", range: r.upperBound..<html.endIndex) else { break }
            from = gt.upperBound
            let attrs = attributes(String(html[r.upperBound..<gt.lowerBound]))
            guard let href = attrs["href"], !href.isEmpty else { continue }
            let rels = (attrs["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            if rels.contains("icon"), icon == nil { icon = decodeEntities(href) }
            else if rels.contains(where: { $0.hasPrefix("apple-touch-icon") }), touch == nil { touch = decodeEntities(href) }
        }
        return icon ?? touch
    }

    static func attributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        let c = Array(s)
        var i = 0
        while i < c.count {
            while i < c.count, c[i].isWhitespace || c[i] == "/" { i += 1 }
            var name = ""
            while i < c.count, !c[i].isWhitespace, c[i] != "=", c[i] != "/" { name.append(c[i]); i += 1 }
            while i < c.count, c[i].isWhitespace { i += 1 }
            var value = ""
            if i < c.count, c[i] == "=" {
                i += 1
                while i < c.count, c[i].isWhitespace { i += 1 }
                if i < c.count, c[i] == "\"" || c[i] == "'" {
                    let q = c[i]; i += 1
                    while i < c.count, c[i] != q { value.append(c[i]); i += 1 }
                    i += 1
                } else {
                    while i < c.count, !c[i].isWhitespace { value.append(c[i]); i += 1 }
                }
            }
            if !name.isEmpty { result[name.lowercased()] = value }
        }
        return result
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'"]
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                var replacement = named[name]
                if replacement == nil, name.hasPrefix("#") {
                    let num = name.dropFirst()
                    let code = num.first.map({ $0 == "x" || $0 == "X" }) == true
                        ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
                    replacement = code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                }
                if let replacement { out += replacement; i = s.index(after: semi); continue }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }

    // MARK: Helpers

    private static func find(_ hay: [UInt8], _ needle: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    private static func dechunk(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < b.count, let eol = find(Array(b[i...]), [13, 10]) {
            let sizeStr = String(decoding: b[i..<(i + eol)], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
            let start = i + eol + 2
            out += b[start..<min(b.count, start + size)]
            i = start + size + 2
        }
        return out
    }
}
