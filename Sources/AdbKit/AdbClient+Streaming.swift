import Foundation

extension AdbClient {
    /// Runs a long-lived shell command and yields its stdout line by line.
    ///
    /// `shell(_:on:)` accumulates output and returns when the command exits,
    /// which is useless for a watcher that never exits. This keeps the transport
    /// open and emits each line as it arrives.
    ///
    /// Deliberately not routed through the concurrency gate: the stream lives
    /// for as long as the device is attached, and holding one of six slots for
    /// hours would starve everything else.
    public func shellLines(_ command: String,
                           on selector: DeviceSelector) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            streamingQueue.async {
                do {
                    // No read timeout: quiet stretches between events are
                    // normal and must not look like failure.
                    let connection = try AdbConnection(endpoint: self.endpoint, ioTimeout: 0)
                    defer { connection.close() }
                    let cancel = connection.canceller
                    continuation.onTermination = { _ in cancel() }

                    try connection.selectTransport(selector)
                    try connection.send("shell,v2,raw:\(command)")

                    var pending = Data()
                    while true {
                        let header: [UInt8]
                        do {
                            header = try connection.readRaw(5)
                        } catch AdbError.unexpectedEOF {
                            continuation.finish()
                            return
                        }
                        let packet = header[0]
                        let length = Int(ByteCodec.readU32(header, at: 1))
                        let payload = length > 0 ? try connection.readRaw(length) : []

                        switch packet {
                        case 1:  // stdout
                            pending.append(contentsOf: payload)
                            while let newline = pending.firstIndex(of: 0x0A) {
                                let line = pending[pending.startIndex..<newline]
                                pending.removeSubrange(pending.startIndex...newline)
                                let text = String(decoding: line, as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                if !text.isEmpty { continuation.yield(text) }
                            }
                        case 3:  // exit
                            continuation.finish()
                            return
                        default:
                            continue  // stderr and control packets are not our concern
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
