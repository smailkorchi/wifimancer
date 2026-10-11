import Foundation

@main
struct CommandTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm-media-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("runner's $HOME `name`.py")
        try "import json, sys; print(json.dumps(sys.argv[1:]))"
            .write(to: script, atomically: true, encoding: .utf8)
        let marker = directory.appendingPathComponent("unexpected-shell-write")
        let file = URL(fileURLWithPath: "/tmp/clip ' \" $HOME $(touch \(marker.path)) `touch \(marker.path)`.mp3")
        let target = "127.0.0.1; touch \(marker.path)"
        let command = MediaAudioCommand.make(
            script: script, target: target, file: file, protocolName: "dlna")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        let arguments = try JSONSerialization.jsonObject(with: data) as! [String]
        precondition(arguments == ["--target", target, "--file", file.path, "--protocol", "dlna"])
        precondition(!FileManager.default.fileExists(atPath: marker.path), "Shell interpreted a file or target argument")

        let missing = Process()
        missing.executableURL = URL(fileURLWithPath: "/bin/bash")
        missing.arguments = ["-lc", MediaAudioCommand.make(
            script: nil, target: "127.0.0.1", file: file, protocolName: "auto")]
        try missing.run()
        missing.waitUntilExit()
        precondition(missing.terminationStatus == 1, "Missing resource must fail")
        let samsung = Device(mac: MACAddress("b8:b4:09:00:00:01")!, ipv4: "192.168.1.3",
                             hostname: "DU7000-fixture", vendor: "Samsung Electronics Co. Ltd")
        precondition(samsung.kind == .tv, "A recognizable Samsung TV must use the TV glyph")
        let gateway = Device(mac: MACAddress("c0:b1:01:00:00:01")!, ipv4: "192.168.1.1", isGateway: true)
        let thisMac = Device(mac: MACAddress("02:00:00:00:01:02")!, ipv4: "192.168.1.102", isSelf: true)
        let noIP = Device(mac: MACAddress("00:11:22:33:44:55")!)
        for id in ["media.audio.smart", "media.dlna.push", "media.airplay.localfile"] {
            let attack = AttackCatalog.all.first { $0.id == id }!
            let selection = ArsenalStore(selectedAttack: attack)
            precondition(selection.compatibleTargets(from: [gateway, thisMac, noIP, samsung]) == [samsung],
                         "Audio selector must include the misclassified Samsung and exclude gateway/self/no-IP")
        }
        print("PASS: literal media arguments survive shell execution; missing resource fails")
        print("PASS: all three audio selectors include correctly classified Samsung TVs")
    }
}
