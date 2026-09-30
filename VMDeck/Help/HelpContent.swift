import Foundation

/// The Help window's content. Inline text is Markdown (bold, `code`).
struct HelpTopic: Identifiable, Hashable {
    enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case steps([String])
        case bullets([String])
        case note(String)
        case code(String)
    }

    let id: String
    let title: String
    let systemImage: String
    let blocks: [Block]

    static let gettingStarted = "getting-started"
    static let hosts = "hosts"
    static let sshSetup = "ssh-setup"
    static let running = "running"
    static let stats = "stats"
    static let resources = "resources"
    static let autoStart = "auto-start"
    static let troubleshooting = "troubleshooting"
    static let security = "security"
}

extension HelpTopic {
    static let all: [HelpTopic] = [
        HelpTopic(id: gettingStarted, title: "Getting Started", systemImage: "sparkles", blocks: [
            .paragraph("VMDeck manages VMware Fusion virtual machines that run **headless**, with no Fusion window, on this Mac or on other Macs over SSH."),
            .paragraph("It doesn't replace Fusion. Each host still needs VMware Fusion installed, and VMDeck drives it with `vmrun`, the command-line tool that ships inside Fusion. Nothing else needs to be installed on the host."),
            .paragraph("VMDeck runs on macOS 15 or later, on Apple silicon and Intel Macs alike. Hosts can be either as well."),
            .heading("First Steps"),
            .steps([
                "Add a host. If Fusion is installed on this Mac, **This Mac** is added for you. For another Mac, click **Set Up Remote Mac** in the sidebar.",
                "Select the host. VMDeck lists every VM it can find there, running or not, and refreshes every 5 seconds.",
                "Use the buttons on each row to start, shut down, suspend, or restart a VM.",
                "Select a VM to see its stats in the panel on the right. ⌥⌘I hides or shows the panel.",
            ]),
            .heading("Keyboard Shortcuts"),
            .bullets([
                "⌘N: Add Host",
                "⇧⌘N: Set Up Remote Mac",
                "⌘R: Refresh",
                "⌥⌘I: Show or hide stats",
                "⌘?: VMDeck Help",
            ]),
        ]),

        HelpTopic(id: hosts, title: "Hosts", systemImage: "server.rack", blocks: [
            .paragraph("A host is a Mac with VMware Fusion installed. VMDeck talks to it in one of two ways:"),
            .bullets([
                "**This Mac**: runs `vmrun` directly.",
                "**SSH**: runs the same commands on another Mac over SSH, using key-based sign-in. VMDeck never asks for or stores a password for everyday use.",
            ]),
            .heading("Adding and Editing Hosts"),
            .paragraph("**Add Host** (⌘N) adds a host you can already SSH into. For a Mac you haven't connected to before, use **Set Up Remote Mac** (⇧⌘N), which takes care of Remote Login, the host key, and a sign-in key."),
            .paragraph("**Edit Host** in the toolbar changes the name, address, user, port, or vmrun path. **Test Connection** runs `vmrun list` on the host and shows exactly what went wrong if it fails."),
            .note("If a Mac's `.local` name stops resolving, which can happen on networks with flaky Bonjour, edit the host and use its IP address instead."),
            .heading("Where VMDeck Looks for VMs"),
            .bullets([
                "VMs that are running (`vmrun list`)",
                "`~/Virtual Machines.localized` and `~/Documents/Virtual Machines.localized`",
                "`/Users/Shared/Virtual Machines`",
                "Fusion's Virtual Machine Library",
                "Any path added with **Add VM Path** in the toolbar",
            ]),
            .paragraph("A VM VMDeck has seen in this session stays listed after it stops, even if it lives somewhere else. VMs whose files are missing, for example on an unmounted drive, don't appear."),
        ]),

        HelpTopic(id: sshSetup, title: "Remote Mac Setup", systemImage: "wand.and.sparkles", blocks: [
            .paragraph("**Set Up Remote Mac** walks through everything a Mac needs before VMDeck can manage it. You can also run it from a host that can't be reached."),
            .heading("1. Find Mac"),
            .paragraph("Type the Mac's hostname or IP address, or pick it from **Nearby Macs**. That list shows Macs on this network that have Remote Login turned on."),
            .paragraph("If the Mac isn't listed, turn on Remote Login on it:"),
            .steps([
                "Open System Settings > General > Sharing.",
                "Turn on **Remote Login**.",
                "Click the info button next to it. Under **Allow access for**, include the account that owns the VMs.",
                "If the VMs are in ~/Documents, also turn on **Allow full disk access for remote users**.",
            ]),
            .heading("2. Trust"),
            .paragraph("The first time, VMDeck shows the Mac's host key fingerprint. On that Mac, run this in Terminal and check that the fingerprints match:"),
            .code("ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub"),
            .paragraph("Trusting saves the key to `~/.ssh/known_hosts`. If the key ever changes, VMDeck refuses to connect until you remove the old key."),
            .heading("3. Sign-in Key"),
            .paragraph("VMDeck creates its own key at `~/.ssh/vmdeck_ed25519` and adds it to the remote user's authorized keys. Enter that user's password once to install it; the password isn't saved. You can also run the `ssh-copy-id` command shown and click **Check Again**."),
            .paragraph("If your existing SSH keys already work, this step is skipped."),
            .heading("4. Fusion"),
            .paragraph("VMDeck checks that `vmrun` works over SSH and that Remote Login sessions can read ~/Documents. Fix anything it flags, or add the host anyway and fix it later."),
        ]),

        HelpTopic(id: running, title: "Running VMs Headless", systemImage: "play.rectangle", blocks: [
            .paragraph("Headless isn't a setting on the VM. It's how the VM was started. **Start** in VMDeck always runs `vmrun start … nogui`, so any VM started here runs without a window."),
            .heading("Actions"),
            .bullets([
                "**Start**: powers the VM on headless.",
                "**Resume**: continues a suspended VM where it left off, headless.",
                "**Shut Down**: asks the guest OS to shut down cleanly, through VMware Tools. VMDeck waits, up to 15 minutes, until the VM has actually powered off, showing **Shutting down** and a timer.",
                "**Power Off**: cuts power immediately, like pulling the plug. Available while a shutdown is in progress, or after a shutdown fails.",
                "**Suspend**: saves the VM's memory to disk and stops it.",
                "**Restart**: asks the guest to restart, or resets it if VMware Tools can't.",
                "**Connect**: opens the guest's screen. Windows guests open in your RDP client (Windows App); macOS and other guests open in Screen Sharing over VNC. The guest has to allow it: Remote Desktop in Windows, Screen Sharing in macOS. Shown only when the VM is running and has an IP address.",
            ]),
            .heading("Moving a VM from a Fusion Window to Headless"),
            .steps([
                "**Suspend** the VM, in VMDeck or in Fusion.",
                "Click **Resume** in VMDeck. It continues right where it was, now without a window.",
            ]),
            .paragraph("Or shut it down and click **Start**. Once a VM runs headless you can quit Fusion. Opening Fusion later reattaches a window to the running VM."),
            .note("A Windows guest installing updates can take a long time to shut down. If Shutting down keeps counting, give it time before using Power Off."),
        ]),

        HelpTopic(id: stats, title: "Stats", systemImage: "chart.bar.xaxis", blocks: [
            .paragraph("VMDeck collects stats in the same call it uses to refresh the list, so they add no extra load on the host."),
            .heading("Host Bar"),
            .paragraph("Above the list: the host's model, macOS version, cores and 1-minute load, memory in use (app, wired, and compressed, as Activity Monitor counts it), and uptime."),
            .heading("Usage Column"),
            .paragraph("**CPU** is the VM's use across its own vCPUs, so 100% means every vCPU is busy. The tooltip also shows it as a share of one host core. The size below it is the memory the VM uses on the host, which can be more than its configured memory because of graphics and other overhead."),
            .heading("Stats Panel"),
            .paragraph("Select a VM. The panel, toggled with ⌥⌘I, shows the VM's IP, whether VMware Tools is running, CPU and memory use, how long it's been running, its configuration, its size on disk, free space on its volume, and a summary of the host."),
            .heading("IP Addresses"),
            .paragraph("The address is what VMware Tools inside the guest publishes to the host. When nothing has been published, VMDeck looks up the VM's MAC address on the host's network and in Fusion's DHCP leases instead. Those addresses show a network icon."),
            .paragraph("**VMware Tools** shows **Running** when the guest is publishing info, **Installed, not responding** when Fusion sees Tools on disk but nothing has arrived from the guest since it booted, and **Not installed** otherwise. A guest that just started can take a minute to report."),
            .note("Fusion's own `vmrun getGuestIPAddress` often claims Tools isn't running after a guest reboots, even when it is. VMDeck doesn't rely on it, so a VM that looks fine in VMDeck but not in Fusion's tools output is expected."),
        ]),

        HelpTopic(id: resources, title: "Editing Resources", systemImage: "slider.horizontal.3", blocks: [
            .paragraph("**Edit**, on a shut-down VM's row or in the stats panel, changes the VM's vCPUs, memory, and disk sizes."),
            .heading("Before You Start"),
            .bullets([
                "The VM must be **shut down**, not suspended. A suspended VM has to be resumed and then shut down, because hardware can't change while its memory is saved.",
                "If Fusion is open on the host, close that VM's window there first. Fusion can overwrite changes to a VM it has open.",
            ]),
            .heading("Processors and Memory"),
            .paragraph("VMDeck saves a copy of the VM's settings as `<name>.vmx.vmdeck-backup` before writing. If the new vCPU count doesn't divide evenly into the VM's cores per socket, VMDeck makes it a single socket."),
            .heading("Storage"),
            .paragraph("Disks can only grow, and growing can't be undone. A disk with snapshots can't be grown until the snapshots are deleted in Fusion."),
            .paragraph("After growing a disk, extend the partition inside the guest:"),
            .bullets([
                "**Windows**: Disk Management > right-click the drive > Extend Volume.",
                "**macOS**: Disk Utility, or `diskutil apfs resizeContainer`.",
                "**Linux**: `growpart` and `resize2fs`, or your distribution's tools.",
            ]),
        ]),

        HelpTopic(id: autoStart, title: "Auto-Start", systemImage: "bolt.badge.clock", blocks: [
            .paragraph("**Auto-Start** in the toolbar picks VMs that a host starts on its own, headless, whenever its user logs in. It's meant for hosts that reboot: after a power cut, an update, or a restart, the VMs come back without anyone opening Fusion."),
            .heading("How It Works"),
            .paragraph("VMDeck installs a small LaunchAgent for the host's user (`~/Library/LaunchAgents/com.vantine.vmdeck.autostart.plist`) that runs a script at login. The script goes through the list in order and, for each VM, **waits for its files to appear** before starting it. That's what makes it safe for VMs on an external RAID or any volume that mounts late: it waits up to the time you set (10 minutes by default), then starts the VM, pauses, and moves on. A VM that's already running is left alone; one whose files never appear is skipped and noted in the log."),
            .heading("Automatic Login Matters"),
            .paragraph("The agent runs at **login**, not at boot. If the host reboots and sits at the login screen, nothing starts until someone logs in. For hands-off reboots, turn on automatic login on that Mac: System Settings > Users & Groups > Automatic login. macOS doesn't allow it while FileVault is on. VMDeck checks this and warns in the Auto-Start sheet."),
            .paragraph("Saving writes the files; the agent becomes active at the host's next login. Until then the status reads \"Installed, loads at next login\", and Run Now still works."),
            .heading("Testing It"),
            .paragraph("**Run Now** runs the same script immediately, so you can check it works without rebooting the host. **Show Log** shows what it did, with timestamps: which VMs it waited for, started, skipped, or couldn't start."),
            .heading("Turning It Off"),
            .paragraph("Untick every VM and Save. VMDeck removes the agent and its files from the host."),
            .note("VMs started this way run headless, exactly as if you'd clicked Start in VMDeck. Fusion doesn't need to be open on the host."),
        ]),

        HelpTopic(id: troubleshooting, title: "Troubleshooting", systemImage: "stethoscope", blocks: [
            .heading("Can't Reach Host"),
            .bullets([
                "**Could not resolve hostname**: check the name. If a `.local` name worked before, try the Mac's IP address.",
                "**Connection refused**: Remote Login is off on that Mac.",
                "**Timed out**: the Mac is asleep, off, or on another network.",
                "**Permission denied**: VMDeck's key isn't installed there. Click **Run SSH Setup**.",
                "**Host key changed**: expected if the Mac was reinstalled. Once you're sure it's the right Mac, remove the old key with the command VMDeck shows, then set it up again.",
            ]),
            .heading("vmrun Not Found"),
            .paragraph("Fusion isn't installed on the host, or is somewhere unusual. Install it, or correct the vmrun path in **Edit Host**. Open Fusion once after installing so it can finish setup."),
            .heading("A VM Is Missing"),
            .paragraph("VMDeck only finds VMs in the places listed under Hosts. Use **Add VM Path** for others. VMs on a drive that isn't mounted don't appear."),
            .paragraph("If the VMs are in ~/Documents on a remote Mac, turn on **Allow full disk access for remote users** in Remote Login's settings there."),
            .heading("No IP Address"),
            .paragraph("The guest's VMware Tools isn't running yet, or the host hasn't seen the VM on the network. Wait for the guest to finish booting, and check that VMware Tools is installed and running inside it."),
            .heading("Shut Down Never Finishes"),
            .paragraph("The guest was asked to shut down but hasn't powered off. It may be installing updates, or an app may be blocking shutdown. Wait, or use **Power Off**."),
            .heading("Start Fails or Hangs Over SSH"),
            .paragraph("Some Fusion versions only start VMs over SSH while the remote user is logged in at that Mac, or after Fusion has been opened there once to accept its license."),
        ]),

        HelpTopic(id: security, title: "Security and Privacy", systemImage: "lock.shield", blocks: [
            .bullets([
                "VMDeck signs in with SSH keys only. The password in Set Up Remote Mac is used once to install the key and is never saved.",
                "VMDeck's key is `~/.ssh/vmdeck_ed25519`. It has no passphrase, because VMDeck connects in the background every few seconds. Remove it from a Mac's `~/.ssh/authorized_keys` to revoke access.",
                "Host keys are checked against `~/.ssh/known_hosts`, and VMDeck refuses to connect when one changes.",
                "Your `~/.ssh/config` applies, including aliases and jump hosts.",
                "On each host, VMDeck only runs `vmrun`, `vmware-vdiskmanager`, and standard read-only system tools (`ps`, `df`, `sysctl`, `vm_stat`, `arp`). It changes files only when you apply resource edits.",
                "The host list is stored at `~/Library/Application Support/VMDeck/hosts.json`.",
            ]),
        ]),
    ]
}
