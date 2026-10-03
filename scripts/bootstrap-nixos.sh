#!/usr/bin/env bash
# Safely deploy this repository's multi-host NixOS configuration.
#
# The script is intentionally self-contained and uses only common NixOS tools.
# It can prepare an already installed system (target root /) or a mounted target
# from the NixOS installer (normally /mnt). It never reuses another machine's
# hardware file unless the caller explicitly selects that existing host profile.

set -Eeuo pipefail

SCRIPT_NAME="$(basename -- "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
NIXOS_SOURCE="$REPO_ROOT/nixos"
if [ -f "$REPO_ROOT/installation/flake.nix" ]; then
    NIXOS_SOURCE="$REPO_ROOT/installation"
fi
# shellcheck source=scripts/lib/custom-service-restore.sh
. "$SCRIPT_DIR/lib/custom-service-restore.sh"

HOST_KEY=""
HOSTNAME_REQUESTED=""
SYSTEM_REQUESTED=""
HARDWARE_REQUESTED=""
TARGET_ROOT="/"
ACTION="prepare"
CREATE_HOST=0
DEPLOY_USER_CONFIG=1
COPY_REPOSITORY=1
ASSUME_YES=0
DRY_RUN=0

WORK_DIR=""
TARGET_CHANGED=0
TARGET_BACKUP=""
STAGE_DIR=""
ACTIVATION_ATTEMPTED=0
ACTIVATION_COMPLETED=0
STAMP="$(date +%Y%m%d-%H%M%S)"

say() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  ./scripts/bootstrap-nixos.sh [options]

Host selection:
  --host NAME            Flake attribute / host directory, for example tonelico
  --hostname NAME        Operating-system hostname; required for a new host
  --system SYSTEM        Nix platform for a new host (default: detected)
  --create-host          Create hosts/NAME when it does not exist
  --hardware FILE        Import a freshly generated hardware-configuration.nix
  --source PATH          Explicit source flake directory (default: portable installation tree)

Deployment target:
  --target-root PATH     Target filesystem root (default: /; installer: /mnt)
  --no-user-config       Do not deploy selected dotfiles and baby-step tools
  --no-copy-repository   Do not copy the clone into the target user's home

Optional final action (choose at most one):
  --build                Build the deployed system, but do not activate it
  --switch               Build first, then switch the currently running system
  --install              Build and run nixos-install for --target-root (not /)

Safety and automation:
  --dry-run              Validate and show the plan without changing anything
  --yes                  Skip the final DEPLOY confirmation
  -h, --help             Show this help

The repository's current desktop is designed for primary user aesc, UID 1000.
EOF
}

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        case "$WORK_DIR" in
            /tmp/nixos-bootstrap.*)
                rm -rf -- "$WORK_DIR"
                ;;
            *)
                warn "Temporary directory was not removed because its path was unexpected: $WORK_DIR"
                ;;
        esac
    fi
    if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
        case "$STAGE_DIR" in
            */.nixos-bootstrap-stage-*)
                if command -v run_root >/dev/null 2>&1; then
                    run_root rm -rf -- "$STAGE_DIR" 2>/dev/null || true
                else
                    rm -rf -- "$STAGE_DIR" 2>/dev/null || true
                fi
                ;;
            *)
                warn "Staging directory was not removed because its path was unexpected: $STAGE_DIR"
                ;;
        esac
    fi
}

on_error() {
    local line="$1"
    local status="$2"
    printf '\nERROR: %s stopped at line %s (exit %s).\n' \
        "$SCRIPT_NAME" "$line" "$status" >&2
    if [ "$TARGET_CHANGED" -eq 1 ]; then
        if [ -n "$TARGET_BACKUP" ] && { [ -e "$TARGET_BACKUP" ] || [ -L "$TARGET_BACKUP" ]; }; then
            printf 'The deployed configuration directory changed. Its previous copy is:\n%s\n' \
                "$TARGET_BACKUP" >&2
        else
            printf 'The deployed configuration directory changed at:\n%s\n' \
                "$TARGET_NIXOS" >&2
        fi
    fi
    if [ "$ACTIVATION_COMPLETED" -eq 1 ]; then
        printf 'A NixOS generation was activated before this failure occurred.\n' >&2
    elif [ "$ACTIVATION_ATTEMPTED" -eq 1 ]; then
        printf 'Activation was attempted before this failure occurred.\n' >&2
    else
        printf 'No NixOS generation was activated by this failure.\n' >&2
    fi
}

trap cleanup EXIT
trap 'on_error "$LINENO" "$?"' ERR

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            [ "$#" -ge 2 ] || fail "--host needs a value"
            [ -n "$2" ] || fail "--host cannot be empty"
            HOST_KEY="$2"
            shift 2
            ;;
        --hostname)
            [ "$#" -ge 2 ] || fail "--hostname needs a value"
            [ -n "$2" ] || fail "--hostname cannot be empty"
            HOSTNAME_REQUESTED="$2"
            shift 2
            ;;
        --system)
            [ "$#" -ge 2 ] || fail "--system needs a value"
            [ -n "$2" ] || fail "--system cannot be empty"
            SYSTEM_REQUESTED="$2"
            shift 2
            ;;
        --hardware)
            [ "$#" -ge 2 ] || fail "--hardware needs a value"
            [ -n "$2" ] || fail "--hardware path cannot be empty"
            HARDWARE_REQUESTED="$2"
            shift 2
            ;;
        --source)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--source needs a value"
            NIXOS_SOURCE="$2"
            shift 2
            ;;
        --target-root)
            [ "$#" -ge 2 ] || fail "--target-root needs a value"
            [ -n "$2" ] || fail "--target-root cannot be empty"
            TARGET_ROOT="$2"
            shift 2
            ;;
        --create-host)
            CREATE_HOST=1
            shift
            ;;
        --no-user-config)
            DEPLOY_USER_CONFIG=0
            shift
            ;;
        --no-copy-repository)
            COPY_REPOSITORY=0
            shift
            ;;
        --build)
            [ "$ACTION" = "prepare" ] || fail "Choose only one final action"
            ACTION="build"
            shift
            ;;
        --switch)
            [ "$ACTION" = "prepare" ] || fail "Choose only one final action"
            ACTION="switch"
            shift
            ;;
        --install)
            [ "$ACTION" = "prepare" ] || fail "Choose only one final action"
            ACTION="install"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

for command_name in \
    bash basename cat chown cmp cp date diff dirname find grep hostname \
    install mkdir mktemp mv nix readlink realpath rm rmdir sed sha256sum stat \
    tar tee awk uname; do
    command -v "$command_name" >/dev/null 2>&1 ||
        fail "Required command is missing: $command_name"
done

[ -d "$NIXOS_SOURCE" ] && [ ! -L "$NIXOS_SOURCE" ] ||
    fail "Source must be a real directory: $NIXOS_SOURCE"
NIXOS_SOURCE="$(realpath -e -- "$NIXOS_SOURCE")"
for required_path in \
    flake.nix flake.lock configuration.nix apps-and-lotus.nix \
    claude-code.nix comic-mono.nix desktop/plasma.nix desktop/niri.nix \
    hosts/README.md; do
    [ -f "$NIXOS_SOURCE/$required_path" ] ||
        fail "Repository is incomplete; missing nixos/$required_path"
done

TARGET_ROOT="$(realpath -m -- "$TARGET_ROOT")"
case "$TARGET_ROOT" in
    /*) ;;
    *) fail "--target-root must resolve to an absolute path" ;;
esac

if [ "$TARGET_ROOT" = "/" ]; then
    TARGET_NIXOS="/etc/nixos"
    TARGET_HOME="/home/aesc"
else
    TARGET_NIXOS="$TARGET_ROOT/etc/nixos"
    TARGET_HOME="$TARGET_ROOT/home/aesc"
fi

case "$TARGET_NIXOS" in
    /etc/nixos|/*/etc/nixos) ;;
    *) fail "Refusing unexpected target configuration path: $TARGET_NIXOS" ;;
esac
custom_restore_safe_path "$TARGET_NIXOS" 1 0 ||
    fail "Configuration destination contains a linked or unsafe component: $TARGET_NIXOS"

if [ "$ACTION" = "switch" ] && [ "$TARGET_ROOT" != "/" ]; then
    fail "--switch is only valid for the currently running system (--target-root /)"
fi
if [ "$ACTION" = "install" ] && [ "$TARGET_ROOT" = "/" ]; then
    fail "--install requires a mounted installation root such as --target-root /mnt"
fi
if [ "$ACTION" = "install" ]; then
    command -v nixos-install >/dev/null 2>&1 || fail "nixos-install is required for --install"
fi
if [ "$ACTION" = "build" ] || [ "$ACTION" = "switch" ]; then
    command -v nixos-rebuild >/dev/null 2>&1 || fail "nixos-rebuild is required for --$ACTION"
fi

validate_host_key() {
    case "$1" in
        ""|*[!A-Za-z0-9._+-]*|-*|.*)
            return 1
            ;;
        *) return 0 ;;
    esac
}

validate_hostname() {
    local value="$1"
    [ "${#value}" -le 63 ] || return 1
    case "$value" in
        ""|*[!A-Za-z0-9.-]*|[-.]*|*[-.]) return 1 ;;
        *) return 0 ;;
    esac
}

detect_system() {
    case "$(uname -m)" in
        x86_64) printf 'x86_64-linux\n' ;;
        aarch64) printf 'aarch64-linux\n' ;;
        *) return 1 ;;
    esac
}

read_host_field() {
    local metadata_file="$1"
    local field="$2"
    BOOTSTRAP_HOST_FILE="$metadata_file" \
    BOOTSTRAP_HOST_FIELD="$field" \
        nix eval --raw --impure --expr '
          let
            host = import (builtins.toPath (builtins.getEnv "BOOTSTRAP_HOST_FILE"));
            field = builtins.getEnv "BOOTSTRAP_HOST_FIELD";
            value = builtins.getAttr field host;
          in if builtins.isString value then value else builtins.toString value
        ' 2>/dev/null
}

detect_host_key() {
    local wanted_hostname="$1"
    local directory
    local metadata_file
    local metadata_hostname
    local found=""

    for directory in "$NIXOS_SOURCE"/hosts/*; do
        [ -d "$directory" ] || continue
        metadata_file="$directory/host.nix"
        [ -f "$metadata_file" ] || continue
        metadata_hostname="$(read_host_field "$metadata_file" hostName || true)"
        if [ "$metadata_hostname" = "$wanted_hostname" ]; then
            if [ -n "$found" ]; then
                fail "More than one host profile matches hostname $wanted_hostname"
            fi
            found="$(basename -- "$directory")"
        fi
    done

    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

CURRENT_HOSTNAME="$(hostname)"
if [ -z "$HOST_KEY" ]; then
    HOST_DETECTION_NAME="${HOSTNAME_REQUESTED:-$CURRENT_HOSTNAME}"
    HOST_KEY="$(detect_host_key "$HOST_DETECTION_NAME" || true)"
    if [ -z "$HOST_KEY" ]; then
        fail "No saved host matches '$HOST_DETECTION_NAME'. Use --host NAME --hostname NAME --create-host."
    fi
fi
validate_host_key "$HOST_KEY" || fail "Invalid host/flake name: $HOST_KEY"

SOURCE_HOST_DIR="$NIXOS_SOURCE/hosts/$HOST_KEY"
SOURCE_HOST_METADATA="$SOURCE_HOST_DIR/host.nix"
SOURCE_HOST_HARDWARE="$SOURCE_HOST_DIR/hardware-configuration.nix"
SOURCE_HOST_MODULE="$SOURCE_HOST_DIR/default.nix"
HOST_EXISTS=0

if [ -f "$SOURCE_HOST_METADATA" ]; then
    HOST_EXISTS=1
    HOST_NAME="$(read_host_field "$SOURCE_HOST_METADATA" hostName)" ||
        fail "Could not read hostName from $SOURCE_HOST_METADATA"
    HOST_SYSTEM="$(read_host_field "$SOURCE_HOST_METADATA" system)" ||
        fail "Could not read system from $SOURCE_HOST_METADATA"
    HOST_USER="$(read_host_field "$SOURCE_HOST_METADATA" primaryUser || true)"
    HOST_UID="$(read_host_field "$SOURCE_HOST_METADATA" userUid || true)"
    HOST_GID="$(read_host_field "$SOURCE_HOST_METADATA" userGid || true)"
    HOST_USER="${HOST_USER:-aesc}"
    HOST_UID="${HOST_UID:-1000}"
    HOST_GID="${HOST_GID:-100}"

    if [ -n "$HOSTNAME_REQUESTED" ] && [ "$HOSTNAME_REQUESTED" != "$HOST_NAME" ]; then
        fail "Host $HOST_KEY is saved with hostname $HOST_NAME, not $HOSTNAME_REQUESTED"
    fi
    if [ -n "$SYSTEM_REQUESTED" ] && [ "$SYSTEM_REQUESTED" != "$HOST_SYSTEM" ]; then
        fail "Host $HOST_KEY is saved for $HOST_SYSTEM, not $SYSTEM_REQUESTED"
    fi
else
    [ "$CREATE_HOST" -eq 1 ] ||
        fail "Host profile $HOST_KEY does not exist. Add --create-host to create it."
    [ -n "$HOSTNAME_REQUESTED" ] ||
        fail "--hostname is required when creating a new host profile"
    HOST_NAME="$HOSTNAME_REQUESTED"
    HOST_SYSTEM="${SYSTEM_REQUESTED:-$(detect_system || true)}"
    HOST_USER="aesc"
    HOST_UID="1000"
    HOST_GID="100"
    validate_hostname "$HOST_NAME" || fail "Invalid hostname: $HOST_NAME"
    [ -n "$HOST_SYSTEM" ] || fail "Could not detect the Nix system; pass --system"
fi

validate_hostname "$HOST_NAME" || fail "Invalid saved hostname: $HOST_NAME"
case "$HOST_SYSTEM" in
    x86_64-linux|aarch64-linux) ;;
    *) fail "Unsupported or unsafe Nix system value: $HOST_SYSTEM" ;;
esac
[ "$HOST_USER" = "aesc" ] ||
    fail "This repository currently requires primaryUser = aesc because desktop paths are intentionally fixed to /home/aesc"
case "$HOST_UID" in
    ""|*[!0-9]*) fail "Invalid numeric user UID in host metadata: $HOST_UID" ;;
esac
case "$HOST_GID" in
    ""|*[!0-9]*) fail "Invalid numeric user GID in host metadata: $HOST_GID" ;;
esac

if [ "$TARGET_ROOT" = "/" ]; then
    BACKUP_BASE="$TARGET_HOME/baby-step/backups/bootstrap-$STAMP"
else
    BACKUP_BASE="$TARGET_ROOT/var/backups/nixos-bootstrap/$STAMP"
fi
custom_restore_validate_new_private_directory "$BACKUP_BASE" \
    "$HOST_UID" "$HOST_GID" ||
    fail "Private recovery location failed preflight: $BACKUP_BASE"

if [ "$DEPLOY_USER_CONFIG" -eq 1 ]; then
    if [ -z "$WORK_DIR" ]; then
        WORK_DIR="$(mktemp -d /tmp/nixos-bootstrap.XXXXXX)" ||
            fail "Could not create private selected-user preflight storage"
        chmod 0700 "$WORK_DIR" || fail "Could not secure selected-user preflight storage"
    fi
    CUSTOM_RESTORE_PREFLIGHT_DIR="$WORK_DIR/selected-user-lists"
    mkdir -m 0700 "$CUSTOM_RESTORE_PREFLIGHT_DIR" ||
        fail "Could not create selected-user entry-list storage"
    CUSTOM_RESTORE_CHECK_REPOSITORY="$COPY_REPOSITORY"
    preflight_selected_user_configuration "$REPO_ROOT" "$TARGET_HOME" \
        "$BACKUP_BASE" "$HOST_UID" "$HOST_GID" \
        "$REPO_ROOT/baby-step/custom-service-manifest.tsv" ||
        fail "Selected-user sources, destinations, or recovery paths failed preflight"
else
    say "Custom-service file restore preflight skipped by --no-user-config."
fi

if [ "$COPY_REPOSITORY" -eq 1 ]; then
    custom_restore_preflight_repository_copy "$REPO_ROOT" "$TARGET_HOME" \
        "$TARGET_HOME/nixos-config" "$BACKUP_BASE/user/nixos-config" \
        "$HOST_UID" "$HOST_GID" ||
        fail "Repository copy source, destination, or recovery path failed preflight"
fi

if [ "$DEPLOY_USER_CONFIG" -eq 1 ] && { [ -e "$REPO_ROOT/wallpapers" ] || [ -L "$REPO_ROOT/wallpapers" ]; }; then
    custom_restore_safe_path "$REPO_ROOT/wallpapers" 0 || fail 'Wallpaper source path failed preflight'
    custom_restore_validate_tree_types "$REPO_ROOT/wallpapers" source || fail 'Wallpaper source types failed preflight'
    custom_restore_validate_destination_directory "$TARGET_HOME/Pictures" "$HOST_UID" "$HOST_GID" || fail 'Pictures destination failed preflight'
    custom_restore_validate_destination_directory "$TARGET_HOME/Pictures/Wallpapers" "$HOST_UID" "$HOST_GID" || fail 'Wallpaper destination failed preflight'
fi

if [ -n "$HARDWARE_REQUESTED" ]; then
    HARDWARE_SOURCE="$(realpath -m -- "$HARDWARE_REQUESTED")"
elif [ -f "$TARGET_NIXOS/hardware-configuration.nix" ]; then
    HARDWARE_SOURCE="$TARGET_NIXOS/hardware-configuration.nix"
elif [ -f "$SOURCE_HOST_HARDWARE" ]; then
    HARDWARE_SOURCE="$SOURCE_HOST_HARDWARE"
else
    fail "No hardware configuration found. Generate one and pass --hardware FILE."
fi

[ -f "$HARDWARE_SOURCE" ] || fail "Hardware configuration does not exist: $HARDWARE_SOURCE"
[ -r "$HARDWARE_SOURCE" ] || fail "Hardware configuration is not readable: $HARDWARE_SOURCE"
[ -s "$HARDWARE_SOURCE" ] || fail "Hardware configuration is empty: $HARDWARE_SOURCE"

BOOTSTRAP_HARDWARE_FILE="$HARDWARE_SOURCE" nix eval --raw --impure --expr '
  let value = import (builtins.toPath (builtins.getEnv "BOOTSTRAP_HARDWARE_FILE"));
  in if builtins.isFunction value then "valid" else throw "hardware file is not a Nix module"
' >/dev/null || fail "Hardware configuration is not a valid Nix module: $HARDWARE_SOURCE"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$(mktemp -d /tmp/nixos-bootstrap.XXXXXX)" ||
        fail "Could not create private bootstrap work storage"
    chmod 0700 "$WORK_DIR" || fail "Could not secure bootstrap work storage"
fi
CANDIDATE="$WORK_DIR/candidate"
mkdir -p "$CANDIDATE"
cp -a "$NIXOS_SOURCE/." "$CANDIDATE/"
mkdir -p "$CANDIDATE/hosts/$HOST_KEY"

if [ "$HOST_EXISTS" -eq 0 ]; then
    cat > "$CANDIDATE/hosts/$HOST_KEY/host.nix" <<EOF
{
  hostName = "$HOST_NAME";
  system = "$HOST_SYSTEM";
  primaryUser = "aesc";
  userUid = 1000;
  userGid = 100;
  extraModules = [ ];
}
EOF
    cat > "$CANDIDATE/hosts/$HOST_KEY/default.nix" <<'EOF'
{ ... }:

{
  # Add only settings proven to be specific to this machine here.
  # CPU/GPU vendor tuning should be reviewed before the first switch.
}
EOF
elif [ ! -f "$CANDIDATE/hosts/$HOST_KEY/default.nix" ]; then
    cat > "$CANDIDATE/hosts/$HOST_KEY/default.nix" <<'EOF'
{ ... }:

{
  # Host-specific settings belong here.
}
EOF
fi

install -m 0644 "$HARDWARE_SOURCE" \
    "$CANDIDATE/hosts/$HOST_KEY/hardware-configuration.nix"

# Keep the conventional root file for nixos-generate-config and human recovery.
# The flake deliberately imports the host-scoped copy above.
install -m 0644 "$HARDWARE_SOURCE" "$CANDIDATE/hardware-configuration.nix"

say "[1/7] Validating repository and host profile..."
EVALUATED_HOSTNAME="$(nix eval --raw \
    "path:$CANDIDATE#nixosConfigurations.$HOST_KEY.config.networking.hostName")" ||
    fail "The candidate flake does not evaluate for host $HOST_KEY"
[ "$EVALUATED_HOSTNAME" = "$HOST_NAME" ] ||
    fail "Candidate hostname mismatch: expected $HOST_NAME, evaluated $EVALUATED_HOSTNAME"
nix eval --raw \
    "path:$CANDIDATE#nixosConfigurations.$HOST_KEY.config.system.build.toplevel.drvPath" \
    >/dev/null || fail "The candidate system configuration does not fully evaluate"
say "[1/7] Validating repository and host profile... OK"

say
say "Deployment plan"
say "  Repository:      $REPO_ROOT"
say "  Flake target:    $TARGET_NIXOS#$HOST_KEY"
say "  Hostname:        $HOST_NAME"
say "  Platform:        $HOST_SYSTEM"
say "  Hardware source: $HARDWARE_SOURCE"
say "  Target root:     $TARGET_ROOT"
say "  Final action:    $ACTION"
if [ "$DEPLOY_USER_CONFIG" -eq 1 ]; then
    say "  User files:      selected files for $TARGET_HOME"
else
    say "  User files:      skipped"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    say
    say "SUCCESS: Dry-run validation passed. Nothing was changed."
    exit 0
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || fail "Interactive confirmation is unavailable; rerun with --yes after reviewing the plan"
    say
    read -r -p 'Type DEPLOY to continue: ' confirmation
    [ "$confirmation" = "DEPLOY" ] || fail "Stopped safely; nothing was deployed"
fi

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    ROOT_COMMAND=( )
elif [ -d "$TARGET_ROOT" ] && [ -w "$TARGET_ROOT" ]; then
    ROOT_COMMAND=( )
else
    command -v sudo >/dev/null 2>&1 || fail "sudo is required to write $TARGET_ROOT"
    ROOT_COMMAND=( sudo )
fi

run_root() {
    "${ROOT_COMMAND[@]}" "$@"
}

BACKUP_PARENT_UID="$HOST_UID"
BACKUP_PARENT_GID="$HOST_GID"
if [ "$TARGET_ROOT" != "/" ] && \
   { [ "${EUID:-$(id -u)}" -eq 0 ] || [ "${#ROOT_COMMAND[@]}" -gt 0 ]; }; then
    BACKUP_PARENT_UID=0
    BACKUP_PARENT_GID=0
fi
custom_restore_ensure_directory "$BACKUP_BASE" "$HOST_UID" "$HOST_GID" \
    0700 "$BACKUP_PARENT_UID" "$BACKUP_PARENT_GID" 0755 ||
    fail "Could not create the private recovery location: $BACKUP_BASE"
custom_restore_validate_private_directory "$BACKUP_BASE" "$HOST_UID" "$HOST_GID" ||
    fail "Created recovery location did not retain private metadata: $BACKUP_BASE"

sync_repository_host_file() {
    local candidate_file="$1"
    local repository_file="$2"
    local relative_name="$3"

    if [ -f "$repository_file" ] && cmp -s "$candidate_file" "$repository_file"; then
        return 0
    fi
    [ -w "$NIXOS_SOURCE" ] || fail "Repository source is not writable: $NIXOS_SOURCE"
    mkdir -p "$(dirname -- "$repository_file")"
    if [ -e "$repository_file" ] || [ -L "$repository_file" ]; then
        run_root install -d -m 0755 "$BACKUP_BASE/repository-host"
        run_root cp -a "$repository_file" \
            "$BACKUP_BASE/repository-host/$relative_name"
    fi
    install -m 0644 "$candidate_file" "$repository_file"
}

say "[2/7] Preserving the host profile in the repository..."
sync_repository_host_file "$CANDIDATE/hosts/$HOST_KEY/host.nix" \
    "$SOURCE_HOST_METADATA" "host.nix"
sync_repository_host_file "$CANDIDATE/hosts/$HOST_KEY/default.nix" \
    "$SOURCE_HOST_MODULE" "default.nix"
sync_repository_host_file "$CANDIDATE/hosts/$HOST_KEY/hardware-configuration.nix" \
    "$SOURCE_HOST_HARDWARE" "hardware-configuration.nix"
say "[2/7] Preserving the host profile in the repository... OK"

say "[3/7] Preparing a recoverable /etc/nixos deployment..."
TARGET_PARENT="$(dirname -- "$TARGET_NIXOS")"
STAGE_DIR="$TARGET_PARENT/.nixos-bootstrap-stage-$STAMP-$$"
run_root install -d -m 0755 "$TARGET_PARENT"
run_root install -d -m 0755 "$STAGE_DIR"
run_root cp -a "$CANDIDATE/." "$STAGE_DIR/"

# Preserve the local /etc/nixos Git recovery history when one already exists.
if [ -d "$TARGET_NIXOS/.git" ]; then
    run_root cp -a "$TARGET_NIXOS/.git" "$STAGE_DIR/.git"
fi

if [ -d "$TARGET_NIXOS" ] && diff -qr --exclude=.git "$STAGE_DIR" "$TARGET_NIXOS" >/dev/null 2>&1; then
    case "$STAGE_DIR" in
        "$TARGET_PARENT"/.nixos-bootstrap-stage-*)
            run_root rm -rf -- "$STAGE_DIR"
            STAGE_DIR=""
            ;;
        *) fail "Refusing to remove unexpected staging path: $STAGE_DIR" ;;
    esac
    say "[3/7] Preparing a recoverable /etc/nixos deployment... ALREADY CURRENT"
else
    if [ -e "$TARGET_NIXOS" ] || [ -L "$TARGET_NIXOS" ]; then
        TARGET_BACKUP="$TARGET_NIXOS.before-bootstrap-$STAMP-$$"
        if [ -e "$TARGET_BACKUP" ] || [ -L "$TARGET_BACKUP" ]; then
            fail "Refusing to overwrite existing backup: $TARGET_BACKUP"
        fi
        run_root mv "$TARGET_NIXOS" "$TARGET_BACKUP"
    fi
    if ! run_root mv "$STAGE_DIR" "$TARGET_NIXOS"; then
        if { [ -e "$TARGET_BACKUP" ] || [ -L "$TARGET_BACKUP" ]; } && [ ! -e "$TARGET_NIXOS" ] && [ ! -L "$TARGET_NIXOS" ]; then
            run_root mv "$TARGET_BACKUP" "$TARGET_NIXOS"
        fi
        fail "Could not place the candidate at $TARGET_NIXOS; previous configuration restored"
    fi
    STAGE_DIR=""
    TARGET_CHANGED=1
    say "[3/7] Preparing a recoverable /etc/nixos deployment... OK"
    if [ -e "$TARGET_BACKUP" ] || [ -L "$TARGET_BACKUP" ]; then
        say "  Previous configuration: $TARGET_BACKUP"
    fi
fi

# Explicit path: references include required new files without changing a Git index.

say "[4/7] Validating the deployed flake..."
DEPLOYED_HOSTNAME="$(nix eval --raw \
    "path:$TARGET_NIXOS#nixosConfigurations.$HOST_KEY.config.networking.hostName")" || {
        if [ "$TARGET_CHANGED" -eq 1 ] && { [ -e "$TARGET_BACKUP" ] || [ -L "$TARGET_BACKUP" ]; }; then
            FAILED_TARGET="$TARGET_NIXOS.failed-$STAMP-$$"
            run_root mv "$TARGET_NIXOS" "$FAILED_TARGET"
            run_root mv "$TARGET_BACKUP" "$TARGET_NIXOS"
            TARGET_CHANGED=0
            fail "Deployed flake validation failed; the previous /etc/nixos was restored"
        fi
        fail "Deployed flake validation failed"
    }
if [ "$DEPLOYED_HOSTNAME" != "$HOST_NAME" ]; then
    if [ "$TARGET_CHANGED" -eq 1 ] && { [ -e "$TARGET_BACKUP" ] || [ -L "$TARGET_BACKUP" ]; }; then
        FAILED_TARGET="$TARGET_NIXOS.failed-$STAMP-$$"
        run_root mv "$TARGET_NIXOS" "$FAILED_TARGET"
        run_root mv "$TARGET_BACKUP" "$TARGET_NIXOS"
        TARGET_CHANGED=0
        fail "Deployed hostname mismatch: expected $HOST_NAME, got $DEPLOYED_HOSTNAME; the previous /etc/nixos was restored"
    fi
    fail "Deployed hostname mismatch: expected $HOST_NAME, got $DEPLOYED_HOSTNAME"
fi
say "[4/7] Validating the deployed flake... OK"

say "[5/7] Deploying selected user configuration..."
if [ "$DEPLOY_USER_CONFIG" -eq 1 ]; then
    deploy_selected_user_configuration "$REPO_ROOT" "$TARGET_HOME" \
        "$BACKUP_BASE" "$HOST_UID" "$HOST_GID" \
        "$REPO_ROOT/baby-step/custom-service-manifest.tsv"
    if [ -d "$REPO_ROOT/wallpapers" ]; then
        custom_restore_ensure_directory "$TARGET_HOME/Pictures" "$HOST_UID" "$HOST_GID"
        backup_and_replace_entry "$REPO_ROOT/wallpapers" "$TARGET_HOME/Pictures/Wallpapers" \
            "$BACKUP_BASE/user/wallpapers" "$HOST_UID" "$HOST_GID"
    fi
    # The fresh installed source is /etc/nixos, not a source path from another machine.
    pointer="$TARGET_HOME/baby-step/state/nixos-source.path"
    if [ -e "$pointer" ] || [ -L "$pointer" ]; then
        run_root cp -a -- "$pointer" "$BACKUP_BASE/nixos-source.path.before"
    fi
    pointer_stage="$(mktemp "$WORK_DIR/nixos-source.XXXXXXXX")"
    printf '/etc/nixos\n' > "$pointer_stage"
    backup_and_replace_entry "$pointer_stage" "$pointer" \
        "$BACKUP_BASE/user/nixos-source.path" "$HOST_UID" "$HOST_GID"
    run_root chmod 600 -- "$pointer"
    say "[5/7] Deploying selected user configuration... OK"
else
    say "[5/7] Deploying selected user configuration... SKIPPED"
fi

say "[6/7] Preserving the cloned repository on the target..."
TARGET_REPOSITORY="$TARGET_HOME/nixos-config"
if [ "$COPY_REPOSITORY" -eq 1 ] && [ "$TARGET_ROOT" != "/" ]; then
    backup_and_replace_entry "$REPO_ROOT" "$TARGET_REPOSITORY" \
        "$BACKUP_BASE/user/nixos-config" "$HOST_UID" "$HOST_GID"
    say "[6/7] Preserving the cloned repository on the target... OK"
elif [ "$COPY_REPOSITORY" -eq 1 ] && \
     [ "$(realpath -m -- "$REPO_ROOT")" = "$(realpath -m -- "$TARGET_REPOSITORY")" ]; then
    say "[6/7] Preserving the cloned repository on the target... ALREADY CURRENT"
else
    say "[6/7] Preserving the cloned repository on the target... SKIPPED"
fi

say "[7/7] Running requested final action..."
case "$ACTION" in
    prepare)
        say "[7/7] Running requested final action... PREPARED ONLY"
        ;;
    build)
        run_root nixos-rebuild build --no-write-lock-file --flake "path:$TARGET_NIXOS#$HOST_KEY"
        say "[7/7] Running requested final action... BUILD OK; NOTHING ACTIVATED"
        ;;
    switch)
        run_root nixos-rebuild build --no-write-lock-file --flake "path:$TARGET_NIXOS#$HOST_KEY"
        ACTIVATION_ATTEMPTED=1
        run_root nixos-rebuild switch --no-write-lock-file --flake "path:$TARGET_NIXOS#$HOST_KEY"
        ACTIVATION_COMPLETED=1
        say "[7/7] Running requested final action... SWITCH OK"
        ;;
    install)
        nix build \
            "path:$TARGET_NIXOS#nixosConfigurations.$HOST_KEY.config.system.build.toplevel" \
            --no-link
        run_root nixos-install --root "$TARGET_ROOT" \
            --flake "path:$TARGET_NIXOS#$HOST_KEY" --no-root-passwd
        say "[7/7] Running requested final action... INSTALL OK"
        ;;
esac

say
say "SUCCESS: Bootstrap completed for $TARGET_NIXOS#$HOST_KEY"
if [ "$ACTION" = "prepare" ]; then
    if [ "$TARGET_ROOT" = "/" ]; then
        say "Nothing was activated. To build safely:"
        say "  sudo nixos-rebuild build --no-write-lock-file --flake path:$TARGET_NIXOS#$HOST_KEY"
    else
        say "Nothing was installed. To install after review:"
        say "  Prefer scripts/install-from-live-usb.py phases; initialize aesc's password before booting."
    fi
fi
say "Backups from this run: $BACKUP_BASE"
say "Review Git changes in: $REPO_ROOT"
