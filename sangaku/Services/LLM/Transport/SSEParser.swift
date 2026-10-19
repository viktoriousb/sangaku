import Foundation

/// One server-sent event.
nonisolated struct SSEEvent: Hashable, Sendable {
    var event: String?
    var data: String
}

/// An incremental server-sent-events parser. Bytes may be split anywhere, including inside a UTF-8 character or
/// between CR and LF. Lines end in LF, CRLF or CR. An event ends at a blank line, or, for servers that omit
/// blank lines, where a new `event:` field starts or the stream ends.
nonisolated struct SSEParser {
    private var pending: [UInt8] = []
    private var lastWasCR = false
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in chunk {
            if lastWasCR {
                lastWasCR = false
                if byte == UInt8(ascii: "\n") { continue }
            }
            switch byte {
            case UInt8(ascii: "\n"):
                line(&events)
            case UInt8(ascii: "\r"):
                lastWasCR = true
                line(&events)
            default:
                pending.append(byte)
            }
        }
        return events
    }

    /// Ends the stream: an unterminated last line and a pending event are delivered.
    mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !pending.isEmpty { line(&events) }
        dispatch(&events)
        return events
    }

    private mutating func line(_ events: inout [SSEEvent]) {
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        if text.isEmpty {
            dispatch(&events)
            return
        }
        if text.hasPrefix(":") { return }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event":
            if !dataLines.isEmpty { dispatch(&events) }
            eventName = String(value)
        case "data":
            dataLines.append(String(value))
        default:
            break
        }
    }

    private mutating func dispatch(_ events: inout [SSEEvent]) {
        defer { eventName = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return }
        events.append(SSEEvent(event: eventName, data: dataLines.joined(separator: "\n")))
    }
}
