# Current restore entry point

The old single-machine restore instructions were replaced by the tested
multi-host deployment workflow.

Read:

```text
docs/MIGRATION-INSTALL.md
```

Use:

```text
scripts/bootstrap-nixos.sh
```

The new workflow preserves or imports freshly generated hardware configuration,
detects or creates host profiles, validates before replacing files, keeps
timestamped backups, deploys selected user configuration, and can build before
switching or installing.

Current Tonelico identity:

- Hostname: `tonelico-nix`
- Flake attribute: `tonelico`
- Explicit target: `/etc/nixos#tonelico`

Do not use the retired `restore-nixos-new-device.sh` workflow for a new
installation; it is hardcoded for the old single-host layout.
