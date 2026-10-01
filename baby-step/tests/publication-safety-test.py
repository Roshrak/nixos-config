#!/usr/bin/env python3
"""Private Git fixtures for publication checks and the backup-only control flow."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "lib/publication-check.py"
REAL_GIT = shutil.which("git")


def run(*args, cwd=None, env=None, input=None, check=True):
    result = subprocess.run(args, cwd=cwd, env=env, input=input,
                            capture_output=True, text=True)
    if check and result.returncode:
        raise AssertionError(f"Command failed: {args[0]} (exit {result.returncode})")
    return result


def initialize(repo):
    repo.mkdir()
    run(REAL_GIT, "init", "-q", "-b", "main", str(repo))
    run(REAL_GIT, "-C", str(repo), "config", "user.name", "Publication Fixture")
    run(REAL_GIT, "-C", str(repo), "config", "user.email", "fixture@example.invalid")
    (repo / "README.md").write_text("Fixture source\n")
    run(REAL_GIT, "-C", str(repo), "add", "README.md")
    run(REAL_GIT, "-C", str(repo), "commit", "-qm", "fixture baseline")


def write(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    if executable:
        path.chmod(0o755)


def scan_case(scratch, name, path, content, accepted, hidden=None):
    repo = scratch / name
    initialize(repo)
    write(repo / path, content)
    run(REAL_GIT, "-C", str(repo), "add", "--", path)
    index = repo / ".git/index"
    before = hashlib.sha256(index.read_bytes()).hexdigest()
    result = run("python3", str(CHECKER), "--repo", str(repo), check=False)
    assert (result.returncode == 0) == accepted, name
    assert hashlib.sha256(index.read_bytes()).hexdigest() == before, name
    if hidden:
        assert hidden not in result.stdout + result.stderr, name


with tempfile.TemporaryDirectory(prefix="publication-safety-test.") as temp:
    scratch = Path(temp)
    scratch.chmod(0o700)
    scan_case(scratch, "approved-helper", "dotfiles/.hermes/agy_bridge.py",
              'import os\napi_key = os.getenv("PROVIDER_KEY")\n', True)
    scan_case(scratch, "private-auth", "dotfiles/.hermes/auth.json", "{}\n", False)
    scan_case(scratch, "env-file", "nixos/.env", "fixture\n", False)
    scan_case(scratch, "runtime", "dotfiles/.config/theme-profiles/test/noctalia-state/clipboard/index.enc",
              "fixture\n", False)
    scan_case(scratch, "cache", "dotfiles/.config/noctalia/.noctalia-cache.json", "{}\n", False)
    scan_case(scratch, "private-log", "baby-step/logs/log.txt", "fixture\n", False)
    scan_case(scratch, "newline", "docs/bad\nname.md", "fixture\n", False)
    scan_case(scratch, "guide", "docs/current-guide.md", "Source guide\n", True)
    synthetic_token = "gh" + "p_" + "A" * 36
    scan_case(scratch, "token", "nixos/source.nix", synthetic_token + "\n", False, synthetic_token)
    synthetic_value = "not" + "-a-real-credential-123"
    scan_case(scratch, "literal", "nixos/source.nix",
              'api' + '_key = "' + synthetic_value + '"\n', False, synthetic_value)
    scan_case(scratch, "placeholder", "docs/guide.md",
              'password = "fixture-password"\n', True)
    print("Full-index path/content refusals, approved helper/docs, environment references, and value redaction: PASS")

    repo = scratch / "workflow"
    initialize(repo)
    bare = scratch / "remote.git"
    run(REAL_GIT, "init", "--bare", "-q", str(bare))
    run(REAL_GIT, "-C", str(repo), "remote", "add", "origin", str(bare))
    run(REAL_GIT, "-C", str(repo), "push", "-q", "-u", "origin", "main")
    baby = repo / "baby-step"
    for rel in ["update-and-push.sh", "lib/common.sh", "lib/source-manifest.sh", "lib/publication-check.py"]:
        (baby / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, baby / rel)
    ignore_source = ROOT.parent / ".gitignore"
    if not ignore_source.is_file():
        ignore_source = Path(os.environ.get("BACKUP_REPO", str(Path.home() / "nixos-config"))) / ".gitignore"
    shutil.copy2(ignore_source, repo / ".gitignore")
    write(baby / "backup-config.sh", "#!/usr/bin/env bash\nexit 0\n", True)
    write(baby / "check-system.sh", "#!/usr/bin/env bash\nexit 0\n", True)
    update_marker = scratch / "UPDATE_MUST_NOT_RUN"
    write(baby / "update-system.sh", f"#!/usr/bin/env bash\ntouch '{update_marker}'\nexit 77\n", True)
    write(repo / "nixos/flake.nix", "{}\n")
    write(repo / "dotfiles/.config/fixture.conf", "fixture\n")
    write(repo / "scripts/fixture.sh", "#!/usr/bin/env bash\nexit 0\n")
    write(repo / "docs/current.md", "Current source guide\n")
    run(REAL_GIT, "-C", str(repo), "add", "-A")
    run(REAL_GIT, "-C", str(repo), "commit", "-qm", "fixture workflow")
    run(REAL_GIT, "-C", str(repo), "push", "-q", "origin", "main")
    write(repo / "dotfiles/.hermes/agy_bridge.py", "# manifest-approved fixture helper\n")
    write(repo / "docs/current.md", "Updated source guide\n")
    bins = scratch / "bin"
    bins.mkdir()
    # Only URL inspection is mapped to the approved name. Fetch and push still
    # use real Git against the private local bare remote; no network is used.
    write(bins / "git", f'''#!/usr/bin/env bash
if [[ " $* " == *" remote get-url "* ]]; then
    printf 'https://github.com/Roshrak/nixos-config.git\\n'
else
    exec '{REAL_GIT}' "$@"
fi
''', True)
    active = str(Path("/run/current-system").resolve())
    write(bins / "nix", f'''#!/usr/bin/env bash
case " $* " in
    *" --json "*) printf '["tonelico"]\\n' ;;
    *"networking.hostName"*) hostname ;;
    *"system.build.toplevel.outPath"*) printf '%s' '{active}' ;;
    *) exit 76 ;;
esac
''', True)
    env = os.environ.copy()
    env.update(BABY_STEP_DIR=str(baby), BACKUP_REPO=str(repo), NIXOS_DIR=str(repo / "nixos"),
               PATH=str(bins) + os.pathsep + env["PATH"])
    outcome = run("bash", str(baby / "update-and-push.sh"), "--backup-only",
                  env=env, input="PUSH\n", check=False)
    if outcome.returncode:
        print(outcome.stdout)
        print(outcome.stderr)
        raise AssertionError("backup-only fixture control flow failed")
    local = run(REAL_GIT, "-C", str(repo), "rev-parse", "HEAD").stdout.strip()
    remote = run(REAL_GIT, "--git-dir", str(bare), "rev-parse", "refs/heads/main").stdout.strip()
    assert local == remote
    for path in ["docs/current.md", "dotfiles/.hermes/agy_bridge.py"]:
        run(REAL_GIT, "--git-dir", str(bare), "cat-file", "-e", "main:" + path)
    assert not update_marker.exists()
    assert str(Path("/run/current-system").resolve()) == active
    print("Actual backup-only script stages approved helper/docs, commits and verifies private-remote push without invoking update: PASS")

    write(repo / "docs/current.md", "Existing staged work\n")
    run(REAL_GIT, "-C", str(repo), "add", "docs/current.md")
    before = hashlib.sha256((repo / ".git/index").read_bytes()).hexdigest()
    refusal = run("bash", str(baby / "update-and-push.sh"), "--backup-only", env=env, check=False)
    assert refusal.returncode != 0 and "Existing staged work" in refusal.stderr
    assert hashlib.sha256((repo / ".git/index").read_bytes()).hexdigest() == before
    assert not update_marker.exists()
    print("Actual entry point refuses pre-existing staged work before update or publication and preserves index: PASS")

print("Publication safety suite: PASS (build/health fixtures are stubbed; runtime system checks are separate)")
