# Custom service file restore scope

`bootstrap-nixos.sh` restores only the exact custom code and user unit files
listed in `baby-step/custom-service-manifest.tsv`. For the Hermes bridge, the
restore copies `dotfiles/.hermes/agy_bridge.py` to the selected target user's
`.hermes/agy_bridge.py`, records the prior file or prior absence under the
bootstrap run's private `custom-services/hermes-bridge` recovery directory,
and verifies the installed hash, mode, and owner. It installs code as mode
`0644`. It does not recursively copy `.hermes`.

The unit is copied by the existing selected `.config` deployment after the
helper restore. Bootstrap does not enable, reload, or start the bridge or its
dependent chat responder. Authentication files, tokens, message history,
cache, and generated runtime environments are not included in the source
manifest or restored by this operation. Configure credentials separately in
the target user's private Hermes state.

## Bootstrap path and copy safety

Before target-root writes, bootstrap checks selected source and destination
trees, selected recovery paths, and the optional whole-repository copy target.
Tree inventory uses physical `find -P` traversal: nested symbolic links are
recorded as links, not traversed; sockets, FIFOs, devices, and other special
file types are refused. The source link policy currently permits only the
repository's exact `obs`, Noctalia-state, and three systemd `default.target.wants`
links and their expected `/home/aesc/...` targets. An identical destination
link can be a no-op. A different destination link is refused. `cp -a` preserves
approved source links and `chown -hR` changes link ownership without following
their targets.

The default whole-repository copy also checks `dotfiles/.hermes` recursively
and permits only the manifest-listed regular `agy_bridge.py`. Any extra file,
directory, or link there—including `.env`, `auth.json`, or cache data—stops the
bootstrap before target-root mutation. This check runs even with
`--no-user-config` when repository copying remains enabled. It does not scan
other repository directories for application-specific secrets; review those
before choosing to copy a repository that contains private data.

Existing target home ownership and mode are preserved. A newly created home
uses mode `0700`; each unique bootstrap recovery base must be a real directory
owned by the selected user with mode `0700`. Existing collisions or unsafe
metadata are refused. The base is created only after the early source,
destination, and collision preflight.

These checks narrow path mistakes but do not make a shell-based check/use
sequence race-proof against an uncooperative process replacing an ancestor at
the exact time of a later filesystem operation. The bootstrap rechecks source
trees and selected paths near deployment, but it does not use descriptor-
relative `openat2` operations or claim arbitrary concurrent-writer safety.
Repository copying and selected-user restoration are not a single atomic
transaction; recovery entries and a retained target may remain after a partial
failure. Read the command's exact error and recovery path before retrying.

## Runtime readiness

**Package/import check: PASS. Full service recreation: NEEDS EVIDENCE.** The
current `agy-bridge.service` names
`/home/aesc/.local/share/nix-roots/hermes-agent-env/bin/python3`, imports
`aiohttp` in the helper, and expects the `agy` CLI through its `PATH`. The
locked flake pins Hermes source tag `v2026.9.24`; its `messaging` package is in
`environment.systemPackages`. On this host, Nix evaluation selected the
Hermes package and its store references included a `hermes-agent-env` Python
environment. With `HOME`, `HERMES_HOME`, and cache redirected to a disposable
directory, that environment imported `aiohttp` successfully (3.14.3). The
unit's `agy` executable also resolves from the declared system profile PATH.

The existing user `nix-roots/hermes-agent-env` symlink currently resolves to
an older Hermes environment than the environment referenced by the locked
system package. Bootstrap does not create or update this link. After the
target's locked system profile is built, derive the environment from that
host's declared system package rather than saving a store hash:

```bash
hermes_package="$(nix eval --offline --no-write-lock-file --raw \
  '/etc/nixos#nixosConfigurations.tonelico.config.environment.systemPackages' \
  --apply 'ps: builtins.head (map toString (builtins.filter (p: builtins.match "hermes-agent-.*" p.name != null) ps))')"
mapfile -t hermes_envs < <(nix-store --query --references "$hermes_package" |
  grep '/hermes-agent-env$')
test "${#hermes_envs[@]}" -eq 1
"${hermes_envs[0]}/bin/python3" -c 'import aiohttp'
install -d -m 0700 "$HOME/.local/share/nix-roots"
ln -sfn -- "${hermes_envs[0]}" \
  "$HOME/.local/share/nix-roots/hermes-agent-env"
```

The discovery and import steps were exercised in a temporary home with the
current locked package. The link installation above is a recovery recipe; it
was not applied to the live home during this repair. Full service readiness
remains unverified because the bootstrap does not provision the link or
authentication, and the bridge unit was not started. Credentials and
provider-facing behavior remain a separate user setup and validation step.
