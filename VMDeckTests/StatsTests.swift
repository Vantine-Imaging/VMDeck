import Foundation
import Testing
@testable import VMDeck

@Suite struct StatsParsingTests {
    // Trimmed from real MacPro1 output.
    static let sample = """
    RUN\t/Users/Shared/Virtual Machines/George.vmwarevm/George.vmx
    VM\t/Users/Shared/Virtual Machines/George.vmwarevm/George.vmx\tWin10 Sage Client George\t0\t2\t8192\twindows9-64\t00:0c:29:6c:9b:3b,
    DF\t/Users/Shared/Virtual Machines/George.vmwarevm/George.vmx\t976797816\t397321380\t/System/Volumes/Data
    VM\t/Volumes/HP1/Virtual Machines/Mail.vmwarevm/Mail.vmx\tMailServer\t0\t6\t24576\tdarwin16-64\t00:0C:29:A6:74:99,00:0c:29:a6:74:a3,
    DF\t/Volumes/HP1/Virtual Machines/Mail.vmwarevm/Mail.vmx\t10497703888\t7253685552\t/Volumes/My Disk
    PS\t41917\t3.2\t9663056\t05:52\t/Applications/VMware Fusion.app/Contents/Library/vmware-vmx -s x=TRUE -@ duplex=3;msgs=ui /Users/Shared/Virtual Machines/George.vmwarevm/George.vmx
    PS\t6777\t3.5\t12592800\t46-19:08:51\t/Applications/VMware Fusion.app/Contents/Library/vmware-vmx -D 4 /Somewhere/Else.vmx
    HOST\t32\t103079215104\t3.47,3.38,3.08\t1786671183\tMacPro7,1\t15.7.7
    MEM\t57425694720
    NET\t192.168.66.130\t00:0c:29:6c:9b:3b
    NET\t192.168.2.143\t0:c:29:6c:9b:3b
    NET\t192.168.2.1\t(incomplete)
    GUEST\t/Users/Shared/Virtual Machines/George.vmwarevm/George.vmx\t192.168.2.143\trunning
    """

    @Test func parsesVMConfigProcessAndVolume() throws {
        let result = Discovery.parse(Self.sample)
        let george = try #require(result.vms.first { $0.displayName == "Win10 Sage Client George" })
        #expect(george.powerState == .running)
        #expect(george.config == VMConfig(vcpus: 2, memoryMB: 8192, guestOS: "windows9-64",
                                          macAddresses: ["00:0c:29:6c:9b:3b"]))
        #expect(george.process == VMProcessStats(pid: 41917, cpuPercent: 3.2,
                                                 residentBytes: 9_663_056 * 1024, uptime: 352))
        #expect(george.volume?.mountPoint == "/System/Volumes/Data")
        #expect(george.guestIP == "192.168.2.143")
        #expect(george.tools == .running)

        let mail = try #require(result.vms.first { $0.displayName == "MailServer" })
        #expect(mail.powerState == .stopped)
        #expect(mail.process == nil)
        #expect(mail.config.macAddresses == ["00:0c:29:a6:74:99", "00:0c:29:a6:74:a3"])
        #expect(mail.volume == VolumeStats(mountPoint: "/Volumes/My Disk",
                                           totalBytes: 10_497_703_888 * 1024, availableBytes: 7_253_685_552 * 1024))
    }

    @Test func parsesHostStats() throws {
        let host = try #require(Discovery.parse(Self.sample).host)
        #expect(host.cpuCount == 32)
        #expect(host.memoryBytes == 103_079_215_104)
        #expect(host.memoryUsedBytes == 57_425_694_720)
        #expect(host.loadAverage == [3.47, 3.38, 3.08])
        #expect(host.bootTime == Date(timeIntervalSince1970: 1_786_671_183))
        #expect(host.model == "MacPro7,1")
        #expect(host.osVersion == "15.7.7")
    }

    @Test func arpBeatsLeaseAndJunkIsIgnored() {
        let neighbors = Discovery.parse(Self.sample).neighbors
        #expect(neighbors == ["00:0c:29:6c:9b:3b": "192.168.2.143"])
    }

    @Test func toolsStateFollowsEvidenceNotTheHandshakeFlag() throws {
        // vmrun says "installed" but Tools published an address: it's running.
        var out = Self.sample.replacing("\t192.168.2.143\trunning", with: "\t192.168.2.143\tinstalled")
        var george = try #require(Discovery.parse(out).vms.first { $0.vmxPath.hasSuffix("George.vmx") })
        #expect(george.tools == .running && george.guestIP == "192.168.2.143")
        // Nothing published, and vmrun says installed.
        out = Self.sample.replacing("\t192.168.2.143\trunning", with: "\t\tinstalled")
        george = try #require(Discovery.parse(out).vms.first { $0.vmxPath.hasSuffix("George.vmx") })
        #expect(george.tools == .installed && george.guestIP == nil)
        // "unknown" printed instead of an address is not an address.
        out = Self.sample.replacing("\t192.168.2.143\trunning", with: "\tunknown\trunning")
        george = try #require(Discovery.parse(out).vms.first { $0.vmxPath.hasSuffix("George.vmx") })
        #expect(george.guestIP == nil)
    }

    @Test func normalizesMACsAndElapsedTimes() {
        #expect(Discovery.normalizeMAC("0:c:29:6c:9b:3b") == "00:0c:29:6c:9b:3b")
        #expect(Discovery.normalizeMAC("00:0C:29:2B:83:41") == "00:0c:29:2b:83:41")
        #expect(Discovery.normalizeMAC("(incomplete)") == nil)
        #expect(Discovery.parseElapsed("05:52") == 352)
        #expect(Discovery.parseElapsed("1:02:03") == 3723)
        let expected: TimeInterval = 46 * 86_400 + 19 * 3600 + 8 * 60 + 51
        #expect(Discovery.parseElapsed("46-19:08:51") == expected)
        #expect(Discovery.parseElapsed("junk") == nil)
    }

    @Test func toolsAddressWinsThenNetwork() {
        let neighbors = ["00:0c:29:6c:9b:3b": "192.168.2.143"]
        let macs = ["00:0c:29:aa:aa:aa", "00:0c:29:6c:9b:3b"]
        let tools = VMStore.chooseIP(guestIP: "10.0.0.5", macs: macs, neighbors: neighbors)
        #expect(tools.0 == "10.0.0.5" && tools.1 == .tools)
        let network = VMStore.chooseIP(guestIP: nil, macs: macs, neighbors: neighbors)
        #expect(network.0 == "192.168.2.143" && network.1 == .network)
        let none = VMStore.chooseIP(guestIP: nil, macs: ["00:0c:29:aa:aa:aa"], neighbors: neighbors)
        #expect(none.0 == nil && none.1 == nil)
    }

    @Test func detectsVMRunCommandsAlreadyRunningOnTheHost() throws {
        let vmx = "/Users/Shared/Virtual Machines/George.vmwarevm/George.vmx"
        let lib = "/Applications/VMware Fusion.app/Contents/Library/vmrun"
        #expect(Discovery.parseOperation("\(lib) -T fusion stop \(vmx) soft", vmx: vmx)! == (.stop, false))
        #expect(Discovery.parseOperation("\(lib) -T fusion stop \(vmx) hard", vmx: vmx)! == (.stop, true))
        #expect(Discovery.parseOperation("\(lib) -T fusion start \(vmx) nogui", vmx: vmx)! == (.start, false))
        #expect(Discovery.parseOperation("\(lib) -T fusion stop /Other.vmx soft", vmx: vmx) == nil)
        #expect(Discovery.parseOperation("\(lib) -T fusion list", vmx: vmx) == nil)

        let output = Self.sample + "\nOP\t02:31\t\(lib) -T fusion stop \(vmx) soft\n"
        let george = try #require(Discovery.parse(output).vms.first { $0.vmxPath == vmx })
        let pending = try #require(george.pending)
        #expect(pending.kind == .stop && !pending.hard)
        #expect(abs(Date.now.timeIntervalSince(pending.startedAt) - 151) < 5)
    }

    @Test func formatsNames() {
        #expect(Format.guestOS("windows9-64") == "Windows 10 (64-bit)")
        #expect(Format.guestOS("windows11-64") == "Windows 11 (64-bit)")
        #expect(Format.guestOS("darwin16-64") == "macOS 10.12")
        #expect(Format.guestOS("darwin21-64") == "macOS 12")
        #expect(Format.guestOS("freebsd13-64") == "freebsd13-64")
        #expect(Format.model("MacPro7,1") == "Mac Pro (MacPro7,1)")
        #expect(Format.model("Mac16,10") == "Mac16,10")
    }
}
