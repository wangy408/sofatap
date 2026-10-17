import Foundation

@main
enum ReceiverProtocolTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description)
            checks += 1
        }
        func rejects(_ description: String, _ action: () throws -> Void) {
            do { try action(); preconditionFailure(description) }
            catch { checks += 1 }
        }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/F1kAAAAASUVORK5CYII="
        let token = String(repeating: "D", count: 43), fingerprint = String(repeating: "a", count: 64)
        func link(_ host: String = "192.0.2.1") -> String {
            "sofatap://pair?host=\(host)&port=53319&token=\(token)&fingerprint=\(fingerprint)"
        }
        func pairing(_ host: String) -> [String: Any] {
            ["host": host, "uri": link(host), "qrPng": png]
        }
        func frame(_ changes: [String: Any] = [:]) throws -> Data {
            var value: [String: Any] = ["type": "state", "name": "客厅 Mac 🛋️", "platform": "macos",
                "inputStatus": "ready", "dryRun": false, "connected": false,
                "pairings": [pairing("192.168.1.5"), pairing("100.64.0.9")]]
            value.merge(changes) { _, new in new }
            return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        }

        // Read realistic byte-by-byte pipe fragmentation, including UTF-8 emoji and multiple frames.
        let first = try frame()
        let second = try frame(["connected": true, "inputStatus": "accessibility_required"])
        var lineBuffer = ReceiverLineBuffer()
        var states: [ReceiverState] = []
        for byte in first + Data([10, 10]) + second + Data([13, 10]) {
            if let data = try lineBuffer.append(byte) { states.append(try ReceiverState.decode(data)) }
        }
        try lineBuffer.finish()
        check(states.count == 2, "split and adjacent NDJSON records must remain distinct")
        check(states[0].name == "客厅 Mac 🛋️", "UTF-8 cannot be decoded before a full frame exists")
        check(!states[0].connected && states[1].connected, "periodic connection state must update")
        check(states[1].inputStatus == "accessibility_required", "permission changes must propagate")
        check(states[0].selectedHost(preserving: "100.64.0.9") == "100.64.0.9", "preserve chosen network")
        check(states[0].selectedHost(preserving: "192.168.9.9") == "192.168.1.5", "removed interfaces cannot keep old QR")
        let noNetwork = try ReceiverState.decode(frame(["pairings": []]))
        check(noNetwork.selectedHost(preserving: "192.168.1.5") == nil, "network loss clears selection")
        check(states[0].pairings[0].pngData?.count == 68, "base64 image bytes round-trip without disk storage")

        var incomplete = ReceiverLineBuffer()
        _ = try incomplete.append(123)
        rejects("EOF with a partial frame must fail") { try incomplete.finish() }
        var oversized = ReceiverLineBuffer()
        for _ in 0..<ReceiverLineBuffer.maximumFrameBytes { _ = try oversized.append(65) }
        rejects("size bound must apply before newline and JSON decoding") { _ = try oversized.append(65) }
        let boundaryFrame = try oversized.append(10)
        check(tryUnwrap(boundaryFrame).count == ReceiverLineBuffer.maximumFrameBytes, "exact boundary remains valid framing")
        rejects("reject invalid JSON") { _ = try ReceiverState.decode(Data("not-json".utf8)) }
        rejects("reject missing required state fields") { _ = try ReceiverState.decode(Data("{}".utf8)) }
        rejects("reject wrong message types") { _ = try ReceiverState.decode(frame(["type": "debug"])) }
        rejects("reject wrong platform") { _ = try ReceiverState.decode(frame(["platform": "windows"])) }
        rejects("reject duplicate interfaces") { _ = try ReceiverState.decode(frame(["pairings": [pairing("192.168.1.5"), pairing("192.168.1.5")]])) }
        rejects("reject excessive interfaces") { _ = try ReceiverState.decode(frame(["pairings": (1...17).map { pairing("192.168.1.\($0)") }])) }
        var badPairing = pairing("192.168.1.5")
        badPairing["uri"] = "https://example.invalid/"
        rejects("never accept browser links as a pairing URI") { _ = try ReceiverState.decode(frame(["pairings": [badPairing]])) }
        badPairing = pairing("192.168.1.5")
        badPairing["qrPng"] = Data("not an image".utf8).base64EncodedString()
        rejects("reject non-PNG payload") { _ = try ReceiverState.decode(frame(["pairings": [badPairing]])) }
        var oversizedImage = Data(base64Encoded: png)!
        oversizedImage.replaceSubrange(16..<20, with: [0, 0, 16, 0])
        badPairing["qrPng"] = oversizedImage.base64EncodedString()
        rejects("reject huge decoded image dimensions") { _ = try ReceiverState.decode(frame(["pairings": [badPairing]])) }
        badPairing = pairing("192.168.1.5\nprivate")
        rejects("reject address control characters") { _ = try ReceiverState.decode(frame(["pairings": [badPairing]])) }
        let future = try ReceiverState.decode(frame(["inputStatus": "future_status", "futureField": true]))
        check(future.inputStatus == "future_status", "unknown statuses stay unavailable in UI but don't break forward-compatible state")
        let base = link()
        func encoded(_ name: String) -> String { name.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        for metadata in ["", "&platform=windows", "&platform=macos", "&platform=linux", "&name=Living+Room",
                         "&platform=macos&name=" + encoded("\u{a0} 客厅 + TV 🛋️ \u{3000}"),
                         "&name=" + String(repeating: "a", count: 80), "&name=" + encoded(String(repeating: "😀", count: 64))] {
            check(ReceiverPairingURI.valid(base + metadata, expectedHost: "192.0.2.1"), "old and metadata desktop QR links accepted")
        }
        for invalid in [base + "&platform=androidtv", base + "&platform=unknown", base + "&platform=",
                        base + "&platform=macos&platform=windows", base + "&name=TV&name=TV", base + "&extra=1",
                        base + "&name=", base + "&name=%20%C2%A0", base + "&name=" + String(repeating: "a", count: 81),
                        base + "&name=" + encoded(String(repeating: "😀", count: 65)),
                        base + "&name=" + encoded(String(repeating: "e\u{301}", count: 41)),
                        base + "&name=TV%00", base + "&name=TV%0A", base + "&name=TV%C2%85",
                        base + "&name=TV%E2%80%8B", base + "&name=TV%E2%80%AE", base + "&name=%FF",
                        base + "&name=%ED%A0%80", base + "&name=%ZZ", base + "&na%6De=TV",
                        base + "&host=192.0.2.1", base + "#", base.replacingOccurrences(of: "//pair?", with: "//tv?"),
                        base.replacingOccurrences(of: "//pair?", with: "//pair/path?"),
                        base.replacingOccurrences(of: "//pair?", with: "//user@pair?"),
                        base.replacingOccurrences(of: "//pair?", with: "//pair:80?"),
                        base.replacingOccurrences(of: "&port=53319", with: ""),
                        base.replacingOccurrences(of: "&port=53319", with: "&port=0"),
                        base.replacingOccurrences(of: token, with: "short"),
                        base.replacingOccurrences(of: fingerprint, with: String(repeating: "g", count: 64)),
                        link("192.0.2.2")] {
            check(!ReceiverPairingURI.valid(invalid, expectedHost: "192.0.2.1"), "ambiguous, mismatched or unsafe QR rejected")
        }
        for command in ReceiverCommand.allCases {
            let bytes = command.line
            check(bytes.last == 10 && bytes.filter { $0 == 10 }.count == 1, "commands have exactly one newline")
            let value = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
            check(value == ["type": command.rawValue], "only the explicit allowlisted command is sent")
        }
        let suite = "Sofatap.PointerSpeed.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(ReceiverPointerSpeed.load(from: defaults) == 1, "missing speed defaults to original")
        for dirty in ["2", true, -1.0, 5.0, Double.nan, Double.infinity] as [Any] {
            defaults.set(dirty, forKey: ReceiverPointerSpeed.defaultsKey)
            check(ReceiverPointerSpeed.load(from: defaults) == 1, "dirty saved speed defaults to original")
        }
        defaults.set(2.5, forKey: ReceiverPointerSpeed.defaultsKey)
        check(ReceiverPointerSpeed.load(from: UserDefaults(suiteName: suite)!) == 2.5,
              "saved speed loads in a new preferences instance")
        for (input, expected) in [(Double.nan, 1.0), (Double.infinity, 1.0), (-1.0, 0.25), (8.0, 4.0), (1.0, 1.0)] {
            check(ReceiverPointerSpeed.normalize(input) == expected, "speed finite/default/clamp")
            let bytes = ReceiverPointerSpeed.commandLine(input)
            let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            check(object.count == 2 && object["type"] as? String == "setPointerSpeed"
                  && object["value"] as? Double == expected && bytes.last == 10,
                  "speed uses strict locale-independent private JSON")
        }
        print("PASS: \(checks) native launcher protocol checks (no UI, child process, network, or real input)")
    }

    private static func tryUnwrap<T>(_ value: T?) -> T { precondition(value != nil); return value! }
}
