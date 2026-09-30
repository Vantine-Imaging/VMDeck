import Foundation

/// A virtual disk attached to a VM.
struct VMDisk: Identifiable, Equatable, Sendable {
    /// The .vmx device key, e.g. "nvme0:0".
    var device: String
    var path: String
    var capacityBytes: Int64?
    /// From the descriptor: monolithicSparse, twoGbMaxExtentSparse,
    /// monolithicFlat (preallocated), …
    var createType: String?
    /// Snapshots or a linked-clone parent: vmware-vdiskmanager can't grow it.
    var hasSnapshots: Bool
    var missing: Bool

    var id: String { device }
    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }
    var isPreallocated: Bool { createType?.lowercased().contains("flat") == true }

    /// Rounded up, so the editor never starts below the real size.
    var currentGB: Int {
        guard let capacityBytes else { return 0 }
        return Int((capacityBytes + 1_073_741_823) / 1_073_741_824)
    }

    var cannotGrowReason: String? {
        if missing { return "The disk file wasn't found." }
        if hasSnapshots { return "This disk has snapshots or is a linked clone. Delete the snapshots in Fusion before growing it." }
        if capacityBytes == nil { return "VMDeck couldn't read this disk's size." }
        return nil
    }
}

struct VMResources: Equatable, Sendable {
    var vcpus: Int
    var memoryMB: Int
    var coresPerSocket: Int?
    var disks: [VMDisk]
    /// The Fusion app is open on the host, so it may overwrite the .vmx.
    var fusionAppRunning: Bool
    /// .lck files next to the VM: something has it open, or it didn't shut down cleanly.
    var locked: Bool
}

/// Requested changes. nil or absent means leave as is.
struct ResourceChange: Equatable, Sendable {
    var vcpus: Int?
    var memoryMB: Int?
    var coresPerSocket: Int?
    /// Disk path → new capacity in MB. Only growing is allowed.
    var diskSizesMB: [String: Int] = [:]

    var isEmpty: Bool { vcpus == nil && memoryMB == nil && coresPerSocket == nil && diskSizesMB.isEmpty }

    /// The changes needed to go from `current` to the requested values. Cores
    /// per socket is only touched when it would no longer divide the vCPU
    /// count, and then the VM becomes a single socket.
    static func between(_ current: VMResources, vcpus: Int, memoryMB: Int, diskSizesMB: [String: Int]) -> ResourceChange {
        var change = ResourceChange()
        if vcpus != current.vcpus {
            change.vcpus = vcpus
            if let cps = current.coresPerSocket, cps > 0, vcpus % cps != 0 {
                change.coresPerSocket = vcpus
            }
        }
        if memoryMB != current.memoryMB { change.memoryMB = memoryMB }
        // Compared with the rounded-up GB the editor displays, so an untouched
        // 60.5 GB disk (shown as 61) isn't grown by half a gigabyte.
        for disk in current.disks where disk.cannotGrowReason == nil {
            guard let requested = diskSizesMB[disk.path] else { continue }
            if requested > disk.currentGB * 1024 { change.diskSizesMB[disk.path] = requested }
        }
        return change
    }
}

/// Reads and changes a stopped VM's CPU, memory, and disk sizes on its host.
struct ResourceEditor: Sendable {
    let vmrun: VMRun

    var vdiskmanagerPath: String {
        URL(fileURLWithPath: vmrun.vmrunPath).deletingLastPathComponent()
            .appending(path: "vmware-vdiskmanager").path
    }

    func inspect(_ vmx: String) async throws -> VMResources {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.inspectScript, "vmdeck-inspect", vmx],
                                                timeout: .seconds(20))
        try VMRun.check(result)
        return try Self.parseInspect(result.stdout)
    }

    /// Returns one line per completed step. Throws on the first failure; steps
    /// before it have already been applied.
    func apply(_ change: ResourceChange, to vmx: String) async throws -> [String] {
        var argv = ["/bin/sh", "-c", Self.applyScript, "vmdeck-apply", vmx, vmrun.vmrunPath, vdiskmanagerPath,
                    change.vcpus.map(String.init) ?? "", change.memoryMB.map(String.init) ?? "",
                    change.coresPerSocket.map(String.init) ?? ""]
        for (path, mb) in change.diskSizesMB.sorted(by: { $0.key < $1.key }) {
            argv += [path, String(mb)]
        }
        // Growing a preallocated disk writes every new byte, which can take a while.
        let result = try await vmrun.runner.run(argv, timeout: .seconds(3600))
        var done: [String] = []
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", maxSplits: 1).map(String.init)
            switch f.first {
            case "OK" where f.count == 2: done.append(f[1])
            case "ERR" where f.count == 2: throw VMRunError.vmrun(f[1])
            default: continue
            }
        }
        if result.status != 0 { try VMRun.check(result) }
        return done
    }

    static func parseInspect(_ output: String) throws -> VMResources {
        var resources = VMResources(vcpus: 1, memoryMB: 0, disks: [], fusionAppRunning: false, locked: false)
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            func field(_ i: Int) -> String { i < f.count ? f[i] : "" }
            switch f.first {
            case "ERR":
                throw VMRunError.vmrun(field(1))
            case "CFG":
                resources.vcpus = Int(field(1)) ?? 1
                resources.memoryMB = Int(field(2)) ?? 0
                resources.coresPerSocket = Int(field(3))
            case "DISK" where f.count >= 3:
                let sectors = Int64(field(3))
                resources.disks.append(VMDisk(
                    device: f[1], path: f[2],
                    capacityBytes: sectors.flatMap { $0 > 0 ? $0 * 512 : nil },
                    createType: field(4).isEmpty ? nil : field(4),
                    hasSnapshots: field(5) == "1",
                    missing: field(6) == "missing"))
            case "FUSION":
                resources.fusionAppRunning = true
            case "LOCK":
                resources.locked = true
            default:
                continue
            }
        }
        return resources
    }

    /// $1 is the .vmx. Prints CFG, one DISK per attached virtual disk, and
    /// FUSION / LOCK flags.
    static let inspectScript = #"""
    export LC_ALL=C
    vmx=$1; dir=$(dirname "$vmx")
    [ -f "$vmx" ] || { printf 'ERR\tCan'"'"'t find %s\n' "$vmx"; exit 0; }
    # .vmx keys are case-insensitive.
    cfg() {
      grep -i "^$1 *=" "${2:-$vmx}" | head -n 1 | sed -n 's/^[^=]*= *"\(.*\)"[[:space:]]*$/\1/p'
    }
    printf 'CFG\t%s\t%s\t%s\n' "$(cfg numvcpus)" "$(cfg memsize)" "$(cfg cpuid.corespersocket)"
    snap=0
    for s in "$dir"/*.vmsd; do
      [ -f "$s" ] || continue
      n=$(cfg snapshot.numsnapshots "$s")
      [ "${n:-0}" -gt 0 ] 2>/dev/null && snap=1
    done
    grep -iE '^(scsi|sata|nvme|ide)[0-9]+:[0-9]+\.filename *=' "$vmx" | while IFS= read -r line; do
      dev=${line%%.*}
      file=$(printf '%s\n' "$line" | sed -n 's/^[^=]*= *"\(.*\)".*$/\1/p')
      case $file in *.vmdk|*.VMDK) ;; *) continue ;; esac
      [ "$(cfg "$dev.present" | tr 'A-Z' 'a-z')" = "false" ] && continue
      case $(cfg "$dev.devicetype" | tr 'A-Z' 'a-z') in *cdrom*|*floppy*) continue ;; esac
      case $file in /*) path=$file ;; *) path="$dir/$file" ;; esac
      if [ ! -f "$path" ]; then
        printf 'DISK\t%s\t%s\t\t\t0\tmissing\n' "$dev" "$path"
        continue
      fi
      # Split and flat disks have a small text descriptor; monolithic sparse
      # disks embed it near the start of the binary file.
      if [ "$(stat -f %z "$path")" -lt 1048576 ]; then
        desc=$(tr -d '\000' < "$path")
      else
        desc=$(head -c 65536 "$path" | tr -d '\000')
      fi
      sectors=$(printf '%s\n' "$desc" | awk '$1 ~ /^(RW|RDONLY|NOACCESS)$/ && $2 ~ /^[0-9]+$/ { s += $2 } END { printf "%.0f", s }')
      ctype=$(printf '%s\n' "$desc" | sed -n 's/^createType *= *"\(.*\)".*/\1/p' | head -n 1)
      dsnap=$snap
      printf '%s\n' "$desc" | grep -qi '^parentFileNameHint' && dsnap=1
      printf 'DISK\t%s\t%s\t%s\t%s\t%s\n' "$dev" "$path" "$sectors" "$ctype" "$dsnap"
    done
    pgrep -xq "VMware Fusion" && printf 'FUSION\t1\n'
    ls -d "$dir"/*.lck >/dev/null 2>&1 && printf 'LOCK\t1\n'
    exit 0
    """#

    /// $1 vmx, $2 vmrun, $3 vmware-vdiskmanager, $4 vCPUs, $5 memory MB,
    /// $6 cores per socket (empty = unchanged), then pairs of disk path and
    /// new size in MB. Refuses unless the VM is fully powered off.
    static let applyScript = #"""
    export LC_ALL=C
    vmx=$1 vmrun=$2 vdm=$3 cpus=$4 mem=$5 cps=$6
    shift 6
    dir=$(dirname "$vmx")
    [ -f "$vmx" ] || { printf 'ERR\tCan'"'"'t find %s\n' "$vmx"; exit 0; }
    real=$(cd "$dir" && pwd -P)/$(basename "$vmx")
    "$vmrun" -T fusion list 2>/dev/null | tail -n +2 | while IFS= read -r p; do
      r=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")
      [ "$r" = "$real" ] && echo running
    done | grep -q running && { printf 'ERR\tThe VM is running. Shut it down first.\n'; exit 0; }
    for s in "$dir"/*.vmss; do
      [ -e "$s" ] && { printf 'ERR\tThe VM is suspended. Start it and shut it down first.\n'; exit 0; }
    done

    if [ -n "$cpus$mem$cps" ]; then
      cp -p "$vmx" "$vmx.vmdeck-backup" || { printf 'ERR\tCouldn'"'"'t back up the .vmx.\n'; exit 0; }
      tmp=$(mktemp "$dir/.vmdeck.XXXXXX") || { printf 'ERR\tCouldn'"'"'t write in the VM folder.\n'; exit 0; }
      awk -v cpus="$cpus" -v mem="$mem" -v cps="$cps" '
        { l = tolower($0) }
        cpus != "" && l ~ /^numvcpus[ \t]*=/ { next }
        mem != "" && l ~ /^memsize[ \t]*=/ { next }
        cps != "" && l ~ /^cpuid\.corespersocket[ \t]*=/ { next }
        { print }
        END {
          if (cpus != "") print "numvcpus = \"" cpus "\""
          if (cps != "") print "cpuid.coresPerSocket = \"" cps "\""
          if (mem != "") print "memsize = \"" mem "\""
        }' "$vmx" > "$tmp" || { rm -f "$tmp"; printf 'ERR\tEditing the .vmx failed.\n'; exit 0; }
      # Rewrite in place so the file keeps its owner and permissions.
      cat "$tmp" > "$vmx" && rm -f "$tmp"
      printf 'OK\tUpdated %s (backup: %s.vmdeck-backup)\n' "$(basename "$vmx")" "$(basename "$vmx")"
    fi

    while [ $# -ge 2 ]; do
      path=$1 mb=$2
      shift 2
      out=$("$vdm" -x "${mb}MB" "$path" 2>&1 </dev/null)
      if [ $? -eq 0 ]; then
        printf 'OK\tGrew %s to %s MB\n' "$(basename "$path")" "$mb"
      else
        printf 'ERR\tGrowing %s failed: %s\n' "$(basename "$path")" "$(printf '%s' "$out" | tr '\n\t' '  ')"
        exit 0
      fi
    done
    exit 0
    """#
}
