#!/usr/bin/env bash

# Read-only system inventory for aesc's local troubleshooting archive.
# The generated report is intentionally redacted and is written beside this
# script. No sudo, package manager, service mutation, or network update is run.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
quick=0
REPORT_DEST=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            printf 'Usage: %s [--quick] [--output NEW_REPORT.md]\n' "$0"
            printf 'Writes a private, dated, redacted inventory. Existing reports are preserved.\n'
            printf 'Full captures are time-bounded; --quick records identity, services and capacity.\n'
            exit 0 ;;
        --quick) quick=1; shift ;;
        --output) [ "$#" -ge 2 ] || { printf 'ERROR: --output needs a path.\n' >&2; exit 2; }; REPORT_DEST="$2"; shift 2 ;;
        *) printf 'ERROR: Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
if [ -z "$REPORT_DEST" ]; then
    mkdir -p "$SCRIPT_DIR/reports" || exit 1
    REPORT_DEST="$SCRIPT_DIR/reports/system-audit-$(date +%Y%m%d-%H%M%S)-$$.md"
fi
[ ! -e "$REPORT_DEST" ] && [ ! -L "$REPORT_DEST" ] || { printf 'ERROR: Report already exists; it was preserved: %s\n' "$REPORT_DEST" >&2; exit 1; }
report_parent="$(dirname -- "$REPORT_DEST")"
[ -d "$report_parent" ] && [ ! -L "$report_parent" ] || { printf 'ERROR: Output directory is missing or linked.\n' >&2; exit 1; }
REPORT="$(umask 077; mktemp "$report_parent/.system-audit.XXXXXX")" || exit 1
trap 'rm -f -- "$REPORT"' EXIT
capture_count=0
capture_failures=0
capture_timeout="${BABY_STEP_AUDIT_TIMEOUT:-45}"
[[ "$capture_timeout" =~ ^[0-9]+$ ]] && ((capture_timeout >= 1 && capture_timeout <= 300)) || { printf 'ERROR: Capture timeout must be 1..300 seconds.\n' >&2; exit 2; }
show_banner 'System inventory report' "Output: $REPORT_DEST"
finish_report() {
    printf '\n--- End of inventory ---\n' >> "$REPORT" || return 1
    ln -- "$REPORT" "$REPORT_DEST" || { printf 'ERROR: Could not publish the report without overwriting a file.\n' >&2; return 1; }
    rm -f -- "$REPORT"
    trap - EXIT
    show_summary 'INVENTORY RECORDED' "$capture_count captures; $capture_failures command failures/timeouts. Report: $REPORT_DEST"
    show_detail 'Recorded output is evidence to interpret; it does not certify the entire system healthy.'
}
STARTED_AT="$(date -Is 2>/dev/null || date)"

redact() {
    redact_output | sed -u -E \
        -e 's#(/dev/disk/by-partuuid/)[^[:space:]]+#\1[REDACTED]#Ig' \
        -e 's#(^[[:space:]]*(Machine ID|Boot ID|deviceUUID|driverUUID|System Token)[[:space:]]*[=:][[:space:]]*).*$#\1[REDACTED]#I'
}

section() {
    printf '\n## %s\n\n' "$1" >> "$REPORT"
    printf '\n  [SECTION] %s\n' "$1"
}

note() {
    printf '%s\n\n' "$1" >> "$REPORT"
}

capture() {
    local label="$1"
    local command_text="$2"
    local output rc
    printf '### %s\n\n**Command:** `%s`\n\n```text\n' "$label" "$command_text" >> "$REPORT"
    capture_count=$((capture_count + 1))
    BABY_STEP_STAGE_LABEL="$label"
    BABY_STEP_STAGE_STARTED=$SECONDS
    printf '  [SCAN %s] %s (limit %ss)\n' "$capture_count" "$label" "$capture_timeout"
    if output="$(timeout "$capture_timeout" bash -o pipefail -c "$command_text" 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    printf '%s\n' "$output" | redact >> "$REPORT"
    if [ "$rc" -ne 0 ]; then
        capture_failures=$((capture_failures + 1))
        show_warning "Capture returned $rc; report retains the limitation."
        printf '[command exit status: %s]\n' "$rc" >> "$REPORT"
    fi
    printf '```\n\n' >> "$REPORT"
    [ "$rc" -ne 0 ] || show_result RECORDED 36
}

capture_file() {
    local label="$1"
    local path="$2"
    printf '### %s\n\n**Path:** `%s`\n\n```text\n' "$label" "$path" >> "$REPORT"
    if [ -r "$path" ]; then
        redact < "$path" >> "$REPORT"
    else
        printf '[not readable or not present]\n' >> "$REPORT"
    fi
    printf '```\n\n' >> "$REPORT"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

safe_env() {
    # Allowlisted desktop/locale/path metadata; unknown variables are omitted.
    local name
    for name in PATH LANG LC_ALL LC_CTYPE LC_MESSAGES TERM SHELL XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_ID XDG_RUNTIME_DIR DISPLAY WAYLAND_DISPLAY NIRI_SOCKET; do
        if [ -n "${!name+x}" ]; then printf '%s=%s\n' "$name" "${!name}"; fi
    done
}

safe_git_config() {
    local repo="$1"
    if [ -d "$repo/.git" ]; then
        printf 'repository: %s\n' "$repo"
        git -C "$repo" branch --show-current 2>/dev/null || true
        git -C "$repo" log -1 --format='HEAD: %H%nDate: %aI%nSubject: %s' 2>/dev/null || true
        printf 'status:\n'
        git -C "$repo" status --short 2>/dev/null || true
        printf 'safe config:\n'
        for key in user.name user.email init.defaultBranch core.editor pull.rebase; do
            value="$(git -C "$repo" config --get "$key" 2>/dev/null || true)"
            [ -n "$value" ] && printf '%s=%s\n' "$key" "$value"
        done
        printf 'credential.helper: '
        if git -C "$repo" config --get-all credential.helper >/dev/null 2>&1; then
            printf 'configured (value omitted)\n'
        else
            printf 'not configured\n'
        fi
        printf 'remotes (credentials stripped):\n'
        git -C "$repo" remote -v 2>/dev/null | sed -E 's#(https?://)([^/@[:space:]]+):([^/@[:space:]]+)@#\1[REDACTED]@#g'
    else
        printf 'not a Git repository\n'
    fi
}

export -f redact redact_output safe_env safe_git_config

cat > "$REPORT" <<EOF
# Comprehensive System Audit

**Audit started:** $STARTED_AT

**Machine:** $( { timeout "$capture_timeout" hostname 2>/dev/null || printf unknown; } | redact )

**Scope:** Read-only local inspection; no configuration, package, service, network, or security changes were performed.

**Redaction:** Secret-like values, authentication material, credential stores, private keys, passwords, cookies, and secret environment-variable values were omitted or replaced with [REDACTED].

## Executive summary

This report is a point-in-time top-to-bottom snapshot for future troubleshooting. It records observable operating-system, hardware, storage, network, runtime, service, security, update, virtualization, and development-workspace state. Command failures and unavailable privileged information are retained as limitations rather than guessed.

This script does not refresh the separate system summaries. The dated output preserves prior reports. Quick mode records only identity, generation paths, failed units, disk and memory; full mode records the broader sections below.
EOF

if [ "$quick" -eq 1 ]; then
    section 'Quick inventory'
    capture 'Identity' 'hostname; uname -a; cat /etc/os-release'
    capture 'Runtime and profile paths' 'readlink -f /run/current-system; readlink -f /run/booted-system; readlink -f /nix/var/nix/profiles/system'
    capture 'Failed system units' 'systemctl --failed --no-legend --plain'
    capture 'Failed user units' 'systemctl --user --failed --no-legend --plain'
    capture 'Storage and memory' 'df -hT; free -h'
    finish_report || exit 1
    exit 0
fi

section "1. System identity and operating system"
capture "Operating-system release" "cat /etc/os-release"
capture "Kernel and architecture" "uname -a; printf '\\n'; uname -m; printf '\\n'; getconf LONG_BIT 2>/dev/null || true"
capture "Hostname and machine identity" "hostnamectl 2>&1 || true; printf '\\n'; hostname -f 2>/dev/null || hostname"
capture "Locale and timezone" "locale 2>&1; printf '\\n'; timedatectl 2>&1 || true"
capture "Boot and uptime" "uptime -s 2>/dev/null || true; uptime; printf '\\n'; who -b 2>/dev/null || true; printf '\\n'; cat /proc/sys/kernel/random/boot_id 2>/dev/null || true; printf '\\n'; systemd-analyze 2>&1 || true"
capture "NixOS version and current system link" "nixos-version 2>&1 || true; readlink -f /run/current-system 2>/dev/null || true; readlink -f /nix/var/nix/profiles/system 2>/dev/null || true"
capture_file "Kernel command line" "/proc/cmdline"

section "2. Hardware inventory"
capture "DMI manufacturer/model/firmware (non-unique fields)" "for f in sys_vendor product_name product_version board_vendor board_name board_version bios_vendor bios_version bios_date chassis_vendor chassis_type; do printf '%s: ' \"\$f\"; cat /sys/class/dmi/id/\"\$f\" 2>/dev/null || printf '[unavailable]'; printf '\\n'; done"
note "Unique hardware serial numbers, product UUIDs, and similar identifiers are intentionally omitted from this report."
capture "PCI hardware" "lspci -nn 2>&1 || true"
capture "USB hardware (serial fields omitted by command selection)" "lsusb 2>&1 || true"
capture "Loaded kernel modules" "lsmod 2>&1 || true"
capture "udev hardware summary" "udevadm info --export-db 2>&1 | sed -E 's/(ID_SERIAL(_SHORT)?|ID_FS_UUID|ID_WWN)=.*/\\1=[REDACTED]/' | head -400 || true"

section "3. CPU and memory"
capture "CPU topology and features" "lscpu 2>&1 || true"
capture "CPU model and vulnerability status" "grep -E '^(model name|Hardware|CPU architecture|vendor_id|flags|bugs|Vulnerabilities)' /proc/cpuinfo /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null | head -160"
capture "Memory usage" "free -h; printf '\\n'; grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapCached|SwapTotal|SwapFree|Zswap|Zswapped|Shmem|Committed_AS|CommitLimit|HugePages_Total|HugePages_Free):' /proc/meminfo"
capture "Swap and compressed swap" "swapon --show --bytes 2>&1 || true; printf '\\n'; zramctl 2>&1 || true"
capture "NUMA and CPU online state" "numactl --hardware 2>&1 || true; printf '\\n'; cat /sys/devices/system/cpu/online 2>/dev/null || true"

section "4. GPU, graphics, displays, and acceleration"
capture "Graphics PCI devices and kernel drivers" "lspci -nnk 2>&1 | awk '/VGA compatible controller|3D controller|Display controller/{show=1; n=0} show{print; n++} show && n>5{show=0}'"
capture "OpenGL renderer and acceleration" "glxinfo -B 2>&1 || true"
capture "Vulkan summary" "vulkaninfo --summary 2>&1 | head -180 || true"
capture "NVIDIA status, if present" "nvidia-smi 2>&1 || true"
capture "Wayland/display configuration" "printf 'WAYLAND_DISPLAY=%s\\nXDG_SESSION_TYPE=%s\\nXDG_CURRENT_DESKTOP=%s\\n' \"\${WAYLAND_DISPLAY:-}\" \"\${XDG_SESSION_TYPE:-}\" \"\${XDG_CURRENT_DESKTOP:-}\"; wlr-randr 2>&1 || true; printf '\\n'; xrandr --listmonitors 2>&1 || true"
capture "Niri outputs and layers" "niri msg outputs 2>&1 || true; printf '\\n'; niri msg layers 2>&1 || true"

section "5. Storage, filesystems, and removable media"
capture "Block devices, models, transport, filesystems, and mounts" "lsblk -e7 -o NAME,PATH,TYPE,SIZE,FSTYPE,FSVER,LABEL,MOUNTPOINTS,MODEL,ROTA,TRAN,RM,HOTPLUG 2>&1 || true"
capture "Filesystem capacity" "df -hT 2>&1; printf '\\n'; df -ih 2>&1"
capture "Mount table" "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS,FSROOT 2>&1 || true"
capture "Disk and partition discovery" "blkid 2>&1 || true"
capture "NVMe inventory (serial numbers redacted)" "nvme list 2>&1 | awk 'NR<=2 {print; next} {\$3=\"[REDACTED]\"; print}' || true"
capture "SMART health (no elevation)" "for d in /dev/nvme* /dev/sd?; do [ -b \"\$d\" ] || continue; printf '\\n### %s\\n' \"\$d\"; smartctl -H \"\$d\" 2>&1 || true; done"
capture "Removable and external storage" "lsblk -o NAME,TYPE,RM,HOTPLUG,TRAN,SIZE,MODEL,MOUNTPOINTS 2>&1 || true"

section "6. Network configuration"
capture "Network interfaces and addresses" "ip -br link; printf '\\n'; ip -br addr"
capture "Routing" "ip route; printf '\\n'; ip -6 route 2>/dev/null || true"
capture "DNS resolver state" "resolvectl status 2>&1 || true; printf '\\n'; sed -E 's/(nameserver[[:space:]]+).*/\\1[REDACTED]/' /etc/resolv.conf 2>/dev/null || true"
capture "NetworkManager state" "nmcli -f GENERAL,CONNECTIVITY,STATE general 2>&1 || true; printf '\\n'; nmcli -f DEVICE,TYPE,STATE,CONNECTION device 2>&1 || true; printf '\\n'; nmcli -f NAME,UUID,TYPE,DEVICE connection show 2>&1 || true"
capture "Listening sockets" "ss -lntup 2>&1 || true"
capture "Neighbor table" "ip neigh 2>&1 || true"

section "7. Drivers and firmware"
capture "Kernel release and firmware directories" "printf 'kernel: '; uname -r; printf '\\n'; ls -ld /lib/firmware /run/current-system/firmware 2>/dev/null || true"
capture "Relevant driver module versions" "for m in i915 amdgpu nouveau nvidia snd_hda_intel ath11k mt7921e iwlwifi rtw89; do if modinfo \"\$m\" >/dev/null 2>&1; then printf '\\n[%s]\\n' \"\$m\"; modinfo -F filename -F version -F srcversion \"\$m\" 2>&1 || true; fi; done"
capture "Bootloader and firmware status" "bootctl status 2>&1 || true; printf '\\n'; mokutil --sb-state 2>&1 || true"
capture "TPM availability" "ls -l /dev/tpm* 2>&1 || true; tpm2_getcap properties-fixed 2>&1 | head -80 || true"

section "8. Installed runtimes, SDKs, compilers, package managers, and CLI tools"
capture "Core tool versions" "for c in nix nixos-rebuild nix-shell nix-env bash sh zsh fish git gh curl wget jq rg fd fzf tmux; do printf '\\n[%s]\\n' \"\$c\"; if command -v \"\$c\" >/dev/null 2>&1; then timeout 8 \"\$c\" --version 2>&1 | head -3 || true; else printf 'not installed\\n'; fi; done"
capture "Compilers and build tools" "for c in gcc g++ clang clang++ make cmake ninja meson pkg-config pkgconf rustc cargo go java javac ruby php perl lua; do printf '\\n[%s]\\n' \"\$c\"; if command -v \"\$c\" >/dev/null 2>&1; then timeout 8 \"\$c\" --version 2>&1 | head -3 || true; else printf 'not installed\\n'; fi; done"
capture "Python installations and tooling" "for c in python python3 python3.13 python3.12 pip pip3 pipx uv poetry rye; do printf '\\n[%s]\\n' \"\$c\"; if command -v \"\$c\" >/dev/null 2>&1; then timeout 8 \"\$c\" --version 2>&1 | head -3 || true; else printf 'not installed\\n'; fi; done; printf '\\nPython executable paths:\\n'; command -v python python3 python3.13 python3.12 2>/dev/null || true; printf '\\nPython virtualenv hints:\\n'; find /home/aesc -maxdepth 4 -type f -path '*/bin/python' -print 2>/dev/null | sort | head -100"
capture "Python package/tool inventories" "python3 -m pip list --format=columns 2>&1 | head -250 || true; printf '\\n'; pipx list 2>&1 || true"
capture "Node.js and JavaScript tooling" "for c in node npm npx pnpm yarn bun deno; do printf '\\n[%s]\\n' \"\$c\"; if command -v \"\$c\" >/dev/null 2>&1; then timeout 8 \"\$c\" --version 2>&1 | head -3 || true; else printf 'not installed\\n'; fi; done; printf '\\nGlobal npm packages:\\n'; timeout 15 npm list --global --depth=0 2>&1 | head -200 || true"
capture "Nix profiles and installed package roots" "nix profile list 2>&1 | head -300 || true; printf '\\n'; nix-env -q 2>&1 | head -300 || true"
capture "Desktop/application package inventories" "flatpak list --columns=application,name,version,installation 2>&1 || true; printf '\\n'; snap list 2>&1 || true"

section "9. Git and development workspace"
capture "Git identity and global safe settings" "for key in user.name user.email init.defaultBranch core.editor pull.rebase credential.helper; do value=\"\$(git config --global --get \"\$key\" 2>/dev/null || true)\"; if [ \"\$key\" = credential.helper ] && [ -n \"\$value\" ]; then value='configured (value omitted)'; fi; [ -n \"\$value\" ] && printf '%s=%s\\n' \"\$key\" \"\$value\"; done; true"
capture "NixOS configuration repository" "safe_git_config /home/aesc/nixos-config"
capture "AGY Control repository" "safe_git_config /home/aesc/agy-control-mcp"
capture "Codex version and configuration file metadata" "codex --version 2>&1; stat -c '%a %U:%G %s bytes %n' /home/aesc/.codex/config.toml 2>&1"
capture "Project instruction files" "find /home/aesc -maxdepth 4 -name AGENTS.md -o -name CLAUDE.md -o -name README.md 2>/dev/null | sort | head -250"
capture "Relevant home workspace directories" "find /home/aesc -maxdepth 2 -mindepth 1 -type d -printf '%p\\n' 2>/dev/null | sort | head -250"

section "10. Environment and PATH"
capture "Redacted environment" "safe_env"
capture "Executable PATH resolution" "printf '%s\\n' \"\${PATH:-}\" | tr ':' '\\n' | nl -ba; printf '\\n'; type -a python3 python node npm git nix codex niri 2>/dev/null || true"
capture "Shell and user identity" "id; printf '\\n'; getent passwd \"\$(id -un)\" | cut -d: -f1,3,4,6,7; printf '\\n'; printf 'shell=%s\\n' \"\${SHELL:-unknown}\""
capture "User limits" "ulimit -a 2>&1 || true"

section "11. Services, processes, startup, and scheduled work"
capture "Failed system services" "systemctl --failed --no-legend --plain 2>&1 || true"
capture "Running system services" "systemctl list-units --type=service --state=running --no-pager --no-legend 2>&1 || true"
capture "Enabled system services" "systemctl list-unit-files --state=enabled --no-pager --no-legend 2>&1 || true"
capture "Failed and running user services" "systemctl --user --failed --no-legend --plain 2>&1 || true; printf '\\n'; systemctl --user list-units --type=service --state=running --no-pager --no-legend 2>&1 || true"
capture "Enabled user services and timers" "systemctl --user list-unit-files --state=enabled --no-pager --no-legend 2>&1 || true; printf '\\n'; systemctl --user list-timers --all --no-pager 2>&1 || true"
capture "System timers" "systemctl list-timers --all --no-pager 2>&1 || true"
capture "Processes (arguments omitted)" "ps -eo user,pid,ppid,stat,etimes,%cpu,%mem,comm --sort=-%cpu 2>&1 | head -220"
capture "Desktop autostart entries" "find /etc/xdg/autostart /home/aesc/.config/autostart -maxdepth 1 -type f -printf '%p\\n' 2>/dev/null | sort"
capture "Cron/at metadata without job contents" "printf 'user crontab: '; crontab -l >/dev/null 2>&1 && printf 'present (contents omitted)\\n' || printf 'absent or inaccessible\\n'; printf 'system cron directories:\\n'; find /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly -maxdepth 1 -type f -printf '%p\\n' 2>/dev/null | sort; printf 'at queue: '; atq 2>&1 || true"

section "12. Virtualization and containers"
capture "Virtualization detection" "systemd-detect-virt --all 2>&1 || true; printf '\\n'; lscpu | grep -Ei 'Hypervisor|Virtualization' || true; printf '\\n'; lsmod | grep -E '^(kvm|vbox|vmw|hv|xen)' || true"
capture "Container runtimes and status" "for c in docker podman nerdctl crictl; do printf '\\n[%s]\n' \"\$c\"; if command -v \"\$c\" >/dev/null 2>&1; then \"\$c\" --version 2>&1 | head -3; \"\$c\" ps -a --format '{{.ID}} {{.Image}} {{.Status}} {{.Names}}' 2>&1 | head -100 || true; else printf 'not installed\\n'; fi; done"
capture "VM tooling" "for c in virsh virt-manager qemu-system-x86_64 qemu-img VirtualBox VBoxManage; do printf '\\n[%s]\n' \"\$c\"; if command -v \"\$c\" >/dev/null 2>&1; then \"\$c\" --version 2>&1 | head -3 || true; else printf 'not installed\\n'; fi; done; printf '\\nWSL is generally not applicable on this Linux host; command check:\\n'; command -v wsl.exe wsl 2>&1 || true"

section "13. Security configuration and status"
capture "Firewall status" "systemctl is-active firewalld 2>&1 || true; systemctl is-active nftables 2>&1 || true; systemctl is-active ufw 2>&1 || true; printf '\\n'; firewall-cmd --state 2>&1 || true; printf '\\n'; ufw status verbose 2>&1 || true; printf '\\n'; nft list ruleset 2>&1 | head -240 || true"
capture "Mandatory access controls" "getenforce 2>&1 || true; aa-status 2>&1 | head -120 || true"
capture "Encryption and Secure Boot indicators" "lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS 2>&1; printf '\\n'; cryptsetup status --all 2>&1 || true; printf '\\n'; mokutil --sb-state 2>&1 || true"
capture "Authentication policy metadata (contents omitted)" "printf 'PAM files:\\n'; find /etc/pam.d -maxdepth 1 -type f -printf '%f\\n' 2>/dev/null | sort; printf '\\nPassword aging for current user:\\n'; chage -l \"\$(id -un)\" 2>&1 | sed -E 's/(Last password change|Password expires|Password inactive|Account expires):.*/\\1: [policy value omitted]/' || true"
capture "Security-relevant permissions" "id; printf '\\n'; getent group wheel sudo docker libvirt 2>/dev/null || true; printf '\\n'; find /home/aesc -maxdepth 2 -type f -perm /6000 -printf '%m %u:%g %p\\n' 2>/dev/null | head -120"

section "14. Power and performance"
capture "Power profile and battery state" "powerprofilesctl get 2>&1 || true; printf '\\n'; upower -e 2>&1 || true; printf '\\n'; upower -i \"\$(upower -e 2>/dev/null | grep -m1 battery || true)\" 2>&1 || true"
capture "CPU frequency and governor" "for f in /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; do printf '%s: ' \"\$f\"; cat \"\$f\" 2>/dev/null || printf '[unavailable]'; printf '\\n'; done"
capture "Thermal zones" "for z in /sys/class/thermal/thermal_zone*; do printf '%s: ' \"\$z\"; cat \"\$z/type\" 2>/dev/null; printf ' temp='; cat \"\$z/temp\" 2>/dev/null; printf '\\n'; done"

section "15. Updates and maintenance state"
capture "NixOS generations" "nixos-rebuild list-generations 2>&1 || true"
capture "Nix channels and flake lock metadata" "nix-channel --list 2>&1 || true; printf '\\n'; stat -c '%y %n' /etc/nixos/flake.lock /home/aesc/nixos-config/installation/flake.lock 2>/dev/null || true"
capture "Maintenance script availability (not executed)" "ls -l /home/aesc/baby-step/check-system.sh /home/aesc/baby-step/update-system.sh"
capture "Maintenance state files" "for f in /home/aesc/baby-step/state/*.txt; do [ -f \"\$f\" ] || continue; printf '\\n===== %s =====\\n' \"\$f\"; sed -n '1,100p' \"\$f\"; done"

section "16. Developer and desktop configuration"
capture "Niri configuration validation" "niri validate -c /home/aesc/.config/niri/config.kdl 2>&1 || true"
capture "Mango configuration validation" "test -s /home/aesc/.config/mango/config.conf; printf 'Static presence only; no safe standalone parser invoked.\\n'"
capture "Noctalia configuration validation" "noctalia_settings_syntax_check; printf 'Settings syntax only; runtime shell acceptance separate.\\n'"
capture "Desktop executable metadata (applications not launched)" "for c in niri mango noctalia kitty nvim chromium steam obs fcitx5 wpctl; do printf '\\n[%s]\\n' \"\$c\"; if executable=\"\$(command -v \"\$c\")\"; then readlink -f -- \"\$executable\"; else printf 'not installed\\n'; fi; done"
capture "Relevant configuration inventory (names and sizes only)" "for d in /home/aesc/.config/niri /home/aesc/.config/mango /home/aesc/.config/noctalia /home/aesc/.config/kitty /home/aesc/.config/Code /home/aesc/.codex; do if [ -d \"\$d\" ]; then printf '\\n[%s]\\n' \"\$d\"; find \"\$d\" -maxdepth 2 -type f -printf '%p %s bytes\\n' 2>/dev/null | sort | head -180; fi; done"

section "17. Detected issues, warnings, and limitations"
note "This section records observations from the commands above; it does not perform repairs. Review command exit-status markers and the detailed sections before acting."
capture "Automated issue scan" "root_pct=\"\$(df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,\"\",\$5); print \$5}')\"; printf 'root_used_percent=%s\\n' \"\${root_pct:-unknown}\"; if [ -n \"\${root_pct:-}\" ] && [ \"\$root_pct\" -ge 85 ]; then printf 'WARNING: root filesystem is at or above 85%%\\n'; fi; system_failed=\"\$(systemctl --failed --no-legend --plain 2>/dev/null || true)\"; if [ -n \"\$system_failed\" ]; then printf 'WARNING: failed system systemd units exist (see service section)\\n'; else printf 'system_failed_units=none\\n'; fi; user_failed=\"\$(systemctl --user --failed --no-legend --plain 2>/dev/null || true)\"; if [ -n \"\$user_failed\" ]; then printf 'WARNING: failed user systemd units exist (see service section)\\n'; else printf 'user_failed_units=none\\n'; fi; for c in smartctl mokutil tpm2_getcap glxinfo vulkaninfo; do command -v \"\$c\" >/dev/null 2>&1 || printf 'INFO: optional command unavailable: %s\\n' \"\$c\"; done"
note "Privileged-only facts such as complete SMART/NVMe health, some TPM details, some firmware variables, and system-wide security policy may be unavailable to the normal user. An unavailable check is not treated as a failure."
note "Historical known items from the prior audit are preserved below for comparison; they are not automatically reclassified as current without a matching current command result."

section "18. Audit records and historical context"
capture "Audit record inventory" "find /home/aesc /tmp /var/tmp -type f \( -iname '*system*audit*' -o -iname '*audit*report*' -o -iname 'system-summary-for-ai.md' \) -print 2>/dev/null | sort"
capture_file "Current AI system summary" "/home/aesc/baby-step/system-summary-for-ai.md"
capture_file "Current concise system summary" "/home/aesc/baby-step/system-summary.txt"
capture_file "Dated historical audit state" "/home/aesc/baby-step/state/audit-2026-08-31.txt"
note "Action taken: a new private dated report was written without replacing previous reports. Separate concise and AI summaries were read as historical context and were not refreshed. Historical audit archives remain preserved."

section "19. Recommended follow-up actions"
note "Investigate current grouped failures and corroborate their impact before planning repairs. A warning, missing optional tool, permission limitation or historical failure does not prove a current defect. Physical or privileged checks unavailable to this collector remain unverified. The report is private because system inventories contain machine and network metadata."

section "20. Commands and tools used"
note "The reproducible collector is baby-step/generate-system-audit.sh. It used standard read-only commands including: cat, date, df, find, free, getent, git, hostnamectl, id, ip, lscpu, lsblk, lsmod, lspci, lsusb, nix, nixos-rebuild, nmcli, niri, noctalia, ps, sed, ss, systemctl, timedatectl, uname, upower, uptime, vulkaninfo, wlr-randr, and optional tools when installed. No sudo command was used. The generator runs bounded local queries only; it does not invoke an independent reviewer or certify repairs."

finish_report || exit 1
