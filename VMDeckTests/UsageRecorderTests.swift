import Foundation
import Testing
@testable import VMDeck

@Suite(.serialized) struct UsageRecorderTests {
    let home: URL
    let runner: LocalRunner

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "vmdeck-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        runner = LocalRunner(environment: env)
    }

    @Test func parsesSeries() {
        let s = UsageRecorderManager.parse("REC\t1\t0\nSINCE\t1700000000\nV\t1700003600\t250.50\t4294967296\nV\t1700000000\t10\t1024\nH\t1700000000\t3.25\t50000000000\t1048576\n")
        #expect(s.recording && !s.loaded)
        #expect(s.since == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(s.vm.map(\.cpuPercent) == [10, 250.5])
        #expect(s.vm.last?.residentBytes == 4_294_967_296)
        #expect(s.host.first?.load1 == 3.25)
        #expect(s.host.first?.swapUsedBytes == 1_048_576)
    }

    @Test func samplerAppendsHostLineAndInstallWritesAgent() async throws {
        // Install without launchctl, then run the sampler it wrote.
        var r = try await runner.run(["/bin/sh", "-c", UsageRecorderManager.installScript, "t", "1", "0",
                                      UsageRecorderManager.samplerScript], timeout: .seconds(10))
        try VMRun.check(r)
        let plist = home.appending(path: "Library/LaunchAgents/\(UsageRecorderManager.label).plist")
        let dict = try #require(NSDictionary(contentsOf: plist))
        #expect(dict["StartInterval"] as? Int == 60)
        let script = home.appending(path: "Library/Application Support/VMDeck/usage.sh").path
        r = try await runner.run(["/bin/sh", script], timeout: .seconds(15))
        #expect(r.status == 0)
        let dir = home.appending(path: "Library/Logs/VMDeck/usage")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(files.count == 1 && files[0].hasSuffix(".tsv"))
        let text = try String(contentsOf: dir.appending(path: files[0]), encoding: .utf8)
        let hostLine = try #require(text.split(whereSeparator: \.isNewline).first { $0.contains("\tHOST\t") })
        let f = hostLine.split(separator: "\t")
        #expect(f.count == 5 && Double(f[2]) != nil && Int64(f[3]) ?? 0 > 1_000_000_000)

        // Removing keeps the data.
        r = try await runner.run(["/bin/sh", "-c", UsageRecorderManager.installScript, "t", "0", "0", ""], timeout: .seconds(10))
        try VMRun.check(r)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: files[0]).path))
    }

    @Test func queryBucketsAndFiltersByVM() async throws {
        let dir = home.appending(path: "Library/Logs/VMDeck/usage")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Int(Date.now.timeIntervalSince1970)
        var lines: [String] = []
        for i in 0..<10 {
            let t = now - 600 + i * 60
            lines.append("\(t)\tVM\t/a/A.vmx\t\(100 + i * 10)\t\(1_048_576 * (i + 1))")
            lines.append("\(t)\tVM\t/b/B.vmx\t5\t1024")
            lines.append("\(t)\tHOST\t\(Double(i))\t\(50_000_000_000 + i)\t0")
        }
        lines.append("\(now - 86_400 * 40)\tVM\t/a/A.vmx\t999\t1")   // outside the range
        let month = { (t: Int) -> String in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM"; return f.string(from: Date(timeIntervalSince1970: TimeInterval(t)))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: dir.appending(path: "\(month(now)).tsv"), atomically: true, encoding: .utf8)

        let r = try await runner.run(["/bin/sh", "-c", UsageRecorderManager.queryScript, "t", "/a/A.vmx", String(now - 3600), "300"],
                                     timeout: .seconds(10))
        try VMRun.check(r)
        let s = UsageRecorderManager.parse(r.stdout)
        #expect(!s.recording)
        #expect(s.vm.count == 2 || s.vm.count == 3)           // 10 minutes in 5-minute buckets
        #expect(s.vm.allSatisfy { $0.cpuPercent >= 100 && $0.cpuPercent <= 190 })
        #expect(s.host.count == s.vm.count)
        #expect(s.since == Date(timeIntervalSince1970: TimeInterval(now - 600)))
        let total = s.vm.reduce(0.0) { $0 + $1.cpuPercent }
        #expect(total < 999)                                   // old sample excluded
    }
}
