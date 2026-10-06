import Foundation

/// One `.vmx` key with the value it should get at the next power cycle.
struct PendingSetting: Identifiable, Hashable, Sendable {
    var id = UUID()
    var key: String
    var value: String

    static let keyCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.:-"))

    static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { keyCharacters.contains($0) } && key.allSatisfy(\.isASCII)
    }

    var isValid: Bool { Self.isValidKey(key) }

    /// The line as it goes into the .vmx.
    var line: String { "\(key) = \"\(value.replacingOccurrences(of: "\"", with: ""))\"" }

    /// Parses `key = "value"`; nil for anything else.
    init?(line: String) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, Self.isValidKey(parts[0]) else { return nil }
        key = parts[0]
        value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    /// Keys people change most, with a hint for the value.
    static let presets: [(key: String, hint: String)] = [
        ("numvcpus", "number of vCPUs, e.g. 4"),
        ("cpuid.coresPerSocket", "cores per socket; equal to numvcpus for one socket"),
        ("memsize", "memory in MB, e.g. 8192"),
        ("mks.enable3d", "TRUE or FALSE, 3D graphics"),
        ("svga.vramSize", "video memory in bytes, e.g. 134217728"),
        ("ethernet0.virtualDev", "e1000e or vmxnet3"),
        ("tools.syncTime", "TRUE or FALSE, clock sync with the host"),
        ("vhv.enable", "TRUE or FALSE, nested virtualization"),
    ]
}

struct PendingSettingsStatus: Equatable, Sendable {
    var pending: [PendingSetting] = []
    /// Current .vmx values for the pending and preset keys.
    var current: [String: String] = [:]
    var vmxWritable = true
}

/// Reads and writes `<name>.vmx.vmdeck-pending` on the host, and can apply it
/// immediately when the VM is off. The scheduled power cycle applies it too.
struct PendingSettingsManager: Sendable {
    let vmrun: VMRun

    func status(for vmxPath: String) async throws -> PendingSettingsStatus {
        let keys = PendingSetting.presets.map(\.key)
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.statusScript, "vmdeck-pending-status", vmxPath] + keys,
                                                timeout: .seconds(20))
        try VMRun.check(result)
        return Self.parseStatus(result.stdout)
    }

    /// Rewrites the pending file; an empty list removes it.
    func save(_ settings: [PendingSetting], for vmxPath: String) async throws {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.saveScript, "vmdeck-pending-save", vmxPath]
                                                + settings.map(\.line), timeout: .seconds(20))
        try VMRun.check(result)
    }

    /// Applies the pending file now. Fails if the VM is running or suspended
    /// (a resume would not pick up hardware changes either). Returns the
    /// lines applied.
    func applyNow(for vmxPath: String) async throws -> [String] {
        let result = try await vmrun.runner.run(["/bin/sh", "-c", Self.applyScript, "vmdeck-pending-apply", vmrun.vmrunPath, vmxPath],
                                                timeout: .seconds(30))
        try VMRun.check(result)
        return result.stdout.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("APPLIED\t") }
            .map { String($0.dropFirst("APPLIED\t".count)) }
    }

    static func parseStatus(_ output: String) -> PendingSettingsStatus {
        var s = PendingSettingsStatus()
        for line in output.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            switch f[0] {
            case "PEND" where f.count >= 2:
                if let p = PendingSetting(line: f[1]) { s.pending.append(p) }
            case "CUR" where f.count >= 3:
                s.current[f[1]] = f[2]
            case "RO":
                s.vmxWritable = false
            default:
                continue
            }
        }
        return s
    }

    // MARK: - Host-side scripts

    /// Shared by the restart runner and Apply Now: merges `<vmx>.vmdeck-pending`
    /// into the .vmx (existing keys replaced case-insensitively, new ones
    /// appended) after backing it up, then removes the pending file. Prints
    /// each line applied.
    static let applyFunction = #"""
    vmdeck_apply_pending() {
      _vmx=$1; _pending="$1.vmdeck-pending"
      [ -s "$_pending" ] || return 0
      cp -p "$_vmx" "$_vmx.vmdeck-backup" || return 1
      while IFS= read -r _line || [ -n "$_line" ]; do
        _key=$(printf '%s' "$_line" | sed -nE 's/^[[:space:]]*([A-Za-z0-9_.:-]+)[[:space:]]*=.*/\1/p')
        [ -n "$_key" ] || continue
        if awk -v k="$_key" 'BEGIN { gsub(/\./, "\\.", k) } tolower($0) ~ "^" tolower(k) "[[:space:]]*=" { f = 1 } END { exit !f }' "$_vmx"; then
          awk -v k="$_key" -v l="$_line" 'BEGIN { gsub(/\./, "\\.", k) } tolower($0) ~ "^" tolower(k) "[[:space:]]*=" { print l; next } { print }' "$_vmx" > "$_vmx.vmdeck-new" && cat "$_vmx.vmdeck-new" > "$_vmx" && rm -f "$_vmx.vmdeck-new"
        else
          printf '%s\n' "$_line" >> "$_vmx"
        fi
        printf '%s\n' "$_line"
      done < "$_pending"
      rm -f "$_pending"
    }
    """#

    /// $1 vmx, then keys whose current values to report.
    static let statusScript = #"""
    vmx=$1; shift
    pending="$vmx.vmdeck-pending"
    [ -w "$vmx" ] || echo "RO"
    if [ -s "$pending" ]; then
      while IFS= read -r line || [ -n "$line" ]; do [ -n "$line" ] && printf 'PEND\t%s\n' "$line"; done < "$pending"
      # Current values for the pending keys too.
      set -- "$@" $(sed -nE 's/^[[:space:]]*([A-Za-z0-9_.:-]+)[[:space:]]*=.*/\1/p' "$pending")
    fi
    for key in "$@"; do
      v=$(awk -v k="$key" 'BEGIN { gsub(/\./, "\\.", k) } tolower($0) ~ "^" tolower(k) "[[:space:]]*=" { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/"/, ""); print; exit }' "$vmx")
      [ -n "$v" ] && printf 'CUR\t%s\t%s\n' "$key" "$v"
    done
    exit 0
    """#

    /// $1 vmx, then the lines to queue. No lines: remove the file.
    static let saveScript = #"""
    vmx=$1; shift
    pending="$vmx.vmdeck-pending"
    [ -f "$vmx" ] || { printf 'ERR\tNo such VM file: %s\n' "$vmx"; exit 0; }
    if [ $# -eq 0 ]; then rm -f "$pending"; echo "OK\tcleared"; exit 0; fi
    : > "$pending" || { printf 'ERR\tCannot write next to the VM: %s\n' "$pending"; exit 0; }
    for line in "$@"; do printf '%s\n' "$line" >> "$pending"; done
    printf 'OK\tqueued %s\n' "$#"
    """#

    /// $1 vmrun, $2 vmx. Applies only when the VM is powered off.
    static let applyScript = applyFunction + #"""

    VMRUN=$1 vmx=$2
    "$VMRUN" -T fusion list 2>/dev/null | grep -qxF "$vmx" && { printf 'ERR\tThe VM is running. Shut it down first, or let the scheduled power cycle apply the settings.\n'; exit 0; }
    dir=$(dirname "$vmx")
    for s in "$dir"/*.vmss; do [ -e "$s" ] && { printf 'ERR\tThe VM is suspended. Settings can only change while it is shut down.\n'; exit 0; }; break; done
    [ -s "$vmx.vmdeck-pending" ] || { printf 'ERR\tNothing is queued.\n'; exit 0; }
    vmdeck_apply_pending "$vmx" | sed 's/^/APPLIED\t/'
    exit 0
    """#
}
