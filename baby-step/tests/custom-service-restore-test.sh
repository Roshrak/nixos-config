#!/usr/bin/env bash
set -euo pipefail

scratch="$(mktemp -d /tmp/custom-service-restore-test.XXXXXX)"
cleanup() {
    case "$scratch" in
        /tmp/custom-service-restore-test.*) rm -rf -- "$scratch" ;;
        *) printf 'Refusing unexpected test cleanup path: %s\n' "$scratch" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$test_dir/../lib/custom-service-manifest.sh"
home="$scratch/home"
dotconfig="$scratch/restore/.config"
local_bin="$scratch/restore/.local/bin"
custom_files="$scratch/restore/custom"
manifest="$scratch/custom-service-manifest.tsv"
mkdir -p "$home/.hermes" "$home/.local/bin" \
    "$home/.config/systemd/user" "$dotconfig/systemd/user" "$local_bin"
printf 'bridge source fixture\n' > "$home/.hermes/agy_bridge.py"
printf 'chat helper fixture\n' > "$home/.local/bin/mc_chat_responder.py"
printf 'bridge unit fixture\n' > "$home/.config/systemd/user/agy-bridge.service"
printf 'chat unit fixture\n' > "$home/.config/systemd/user/mc-chat-responder.service"
chmod 755 "$home/.hermes/agy_bridge.py" "$home/.local/bin/mc_chat_responder.py"
cp "$home/.config/systemd/user/agy-bridge.service" "$dotconfig/systemd/user/agy-bridge.service"
cp "$home/.config/systemd/user/mc-chat-responder.service" "$dotconfig/systemd/user/mc-chat-responder.service"
printf 'unrelated backup file\n' > "$local_bin/keep-existing.sh"
printf 'secret fixture\n' > "$home/.hermes/.env"
printf 'credential fixture\n' > "$home/.hermes/auth.json"
cat > "$manifest" <<'MANIFEST'
# source-home-relative<TAB>backup-dotfiles-relative<TAB>kind
.hermes/agy_bridge.py	.hermes/agy_bridge.py	code
.local/bin/mc_chat_responder.py	.local/bin/mc_chat_responder.py	code
.config/systemd/user/agy-bridge.service	.config/systemd/user/agy-bridge.service	unit
.config/systemd/user/mc-chat-responder.service	.config/systemd/user/mc-chat-responder.service	unit
MANIFEST

prepare_custom_service_sources "$manifest" "$home" "$dotconfig" "$local_bin" "$custom_files"
cmp -s "$home/.hermes/agy_bridge.py" "$custom_files/.hermes/agy_bridge.py"
cmp -s "$home/.local/bin/mc_chat_responder.py" "$local_bin/mc_chat_responder.py"
cmp -s "$home/.config/systemd/user/agy-bridge.service" "$dotconfig/systemd/user/agy-bridge.service"
cmp -s "$home/.config/systemd/user/mc-chat-responder.service" "$dotconfig/systemd/user/mc-chat-responder.service"
test -f "$local_bin/keep-existing.sh"
test ! -e "$custom_files/.hermes/.env"
test ! -e "$custom_files/.hermes/auth.json"
test "$(find "$custom_files" "$local_bin" "$dotconfig" -type f | wc -l)" -eq 5
printf 'Declared code and matching unit restore; secrets and unrelated files excluded: PASS\n'

missing_home="$scratch/missing-home"
cp -a "$home" "$missing_home"
cp -a "$dotconfig" "$scratch/missing-dotconfig"
cp -a "$local_bin" "$scratch/missing-local-bin"
rm -- "$missing_home/.hermes/agy_bridge.py"
if prepare_custom_service_sources "$manifest" "$missing_home" "$scratch/missing-dotconfig" \
    "$scratch/missing-local-bin" "$scratch/missing-custom" > /dev/null 2>&1; then
    printf 'Missing custom service helper was accepted\n' >&2
    exit 1
fi
test -z "$(find "$scratch/missing-custom" -type f -print -quit 2>/dev/null || true)"
printf 'Missing helper rejected before any repository replacement: PASS\n'

if prepare_custom_service_sources "$manifest" "$home" "$scratch/wrong-dotconfig" \
    "$scratch/wrong-local-bin" "$scratch/wrong-custom" > /dev/null 2>&1; then
    printf 'Missing matching systemd unit snapshot was accepted\n' >&2
    exit 1
fi
printf 'Missing unit snapshot rejected: PASS\n'

printf '.hermes/agy_bridge.py\t/etc/passwd\tcode\n' > "$scratch/unapproved.tsv"
if prepare_custom_service_sources "$scratch/unapproved.tsv" "$home" "$dotconfig" \
    "$scratch/unapproved-local-bin" "$scratch/unapproved-custom" > /dev/null 2>&1; then
    printf 'Unapproved custom-service path was accepted\n' >&2
    exit 1
fi
printf 'Unapproved source/destination mapping rejected: PASS\n'
