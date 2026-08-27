# Multi-DE Integration — Master Plan

> Every desktop/session must behave as though it is the only custom desktop on the system.
> Mango+Noctalia and KDE are protected fallbacks at all times.

**Created:** 2026-08-26 · **Machine:** tonelico-nix (NixOS 26.05, Intel Meteor Lake iGPU)
**Decisions locked:** II via scratch-user trial first · GNOME without GDM (greetd stays) · niri from upstream flake

---

## Session set & reliability hierarchy

> **DECISION 2026-08-26:** Final set is THREE sessions — Mango+Noctalia, KDE,
> Niri+Noctalia. i3 removed entirely; GNOME and Hyprland phases dropped.

1. Mango 0.16.1 + Noctalia v5.0.0  ← primary fallback, never break
2. KDE Plasma 6.6.6               ← second fallback, never break
3. Niri + Noctalia v5             ← own Noctalia profile
4. ~~GNOME~~ (dropped by decision)
5. ~~i3/X11~~ (removed, all traces purged)
6. ~~Hyprland + II~~ (dropped by decision)

## Ownership model

| Component | Mango | KDE | Niri | Hyprland | GNOME | i3/X11 |
|---|---|---|---|---|---|---|
| Compositor | mango | kwin_wayland | niri | Hyprland | Mutter | i3 |
| Shell/bar | Noctalia v5 (mango profile) | Plasma shell | Noctalia v5 (**niri profile**) | Illogical Impulse | GNOME Shell | Polybar |
| Launcher | Noctalia | KRunner | Noctalia | II launcher | GNOME | Rofi |
| Notifications | Noctalia | Plasma | Noctalia | II stack | GNOME Shell | Dunst |
| Portal conf | mango-portals.conf | kde.portal (auto) | niri-portals.conf (gtk+gnome+keyring) | default=gtk | GNOME portal | gtk only (`XDG_CURRENT_DESKTOP=i3`) |
| Polkit agent | (audited in P0 → audit report) | plasma agent | spawn-at-startup agent | II's choice | gnome-shell built-in | lxpolkit / polkit-gnome (one) |
| Lock/idle | Noctalia | kscreenlocker | Noctalia (niri profile) | hypridle/hyprlock (II) | GNOME | i3lock-color + xss-lock |
| Wallpaper | Noctalia | Plasma | Noctalia (niri profile) | II (matugen/swww) | GNOME | feh/nitrogen |
| Clipboard | Noctalia history | Klipper | Noctalia | II | GNOME | cliphist |
| Theme stamping | apply-theme-profile mango ✅ | apply-theme-profile kde ✅ | new niri entry | new hyprland entry | native dconf | own GTK ini inside ~/.config/i3/ scope |
| Env scoping | env= lines in config.conf | plasma-workspace/env/*.sh | niri env block | env= in hyprland.conf | session-inherited only | i3 exec/env |
| XWayland | builtin | builtin | **xwayland-satellite** | builtin | builtin | native |

Shared (OS-owned, verified safe): kernel/drivers/iHD VA-API, PipeWire+WirePlumber, NetworkManager,
BlueZ, UPower, udisks2, fonts, greetd+noctalia-greeter, kitty, chromium, gnome-keyring/PAM.

## Key conflicts (from P0 research)

1. **Noctalia state is shared** between compositor sessions (`~/.local/state/noctalia/settings.toml`,
   template engine rewrites kitty/gtk/btop… like the wallpaper-kitty leak fixed 2026-08-26).
   Niri session gets its **own Noctalia profile**: either a state/config overlay mechanism or
   per-session snapshot/restore of the shared files via `apply-theme-profile`. Duplicate configs accepted.
2. **Portals:** one `<desktop>-portals.conf` per DE; never touch the global default.
   niri needs xdg-desktop-portal-gnome (screencast) + gtk + gnome-keyring.
3. **greetd teardown is abrupt:** stale systemd-user units accumulate per DE
   (proven: stale plasma units caused black-screen re-login). Generalize
   `01-reset-stale-plasma.sh` pattern into a reset script per experimental DE;
   Mango/KDE scripts stay untouched.
4. **Env hygiene:** no global GDK_BACKEND (breaks niri screencast portal);
   keep existing globals (NIXOS_OZONE_WL, MOZ_ENABLE_WAYLAND, XMODIFIERS); all
   compositor-specific vars live in that compositor's config only.
5. **i3/X11** needs an xsessions entry exposed to noctalia-greeter (extend the
   dm-sessions-share trick beyond wayland-sessions) + sets XDG_CURRENT_DESKTOP=i3 in-session.
6. **GNOME without GDM:** accept documented minor quirks; explicitly do not enable GDM;
   watch that services.desktopManager.gnome.enable doesn't pull global portal/GTK overrides.

## Installation order

Niri → i3 → GNOME → Hyprland+II  (ascending risk; full regression gate after each)

## Phases

- [x] **P0 Audit** → see `01-audit-report.md` (+ raw dumps in `audit/`)
- [x] **P1 Backup** → `02-backup-recovery.md`; baseline tarball created 2026-08-26
      ⚠️ git commit of `/etc/nixos` pending: needs one sudo command (see recovery doc §commands)
- [x] **P2 Isolation architecture** → table above
- [x] **P3 Conflict map** → list above
- [x] **P5 Niri + Noctalia** ✅ login-tested 2026-08-26; keybinds now mirror Mango
      (see `10-phase-niri.md`); regression gate on Mango/KDE = pass
- [x] **P6 i3** → REMOVED from system+user config per decision (commit "remove i3")
      xsessions exposed to greeter, light-theme profile `i3`);
      awaiting rebuild #3 + login test
- [ ] ~~P7 GNOME~~ dropped by decision
- [ ] ~~P8 Hyprland+II~~ dropped by decision
- [ ] **P9 Services/portals/auth finalization** (per-DE reset scripts, agents)
- [ ] **P10 Per-session validation matrix**
- [ ] **P11 Cross-session transition matrix** (all pairs incl. Wayland↔X11)

## Regression rule (enforced every phase)

After ANY change: log into Mango+Noctalia (bar, launcher, notif, screenshot OK) AND KDE
(login, lock/unlock, portal file dialog OK). Failure ⇒ stop, revert generation / restore
backup, retest both, only then continue. Never stack fixes on broken fallbacks.

## Change documentation template

Every change: Purpose · Scope (global/de-only) · Files affected · Commands · Risks ·
Verification · Mango regression test · KDE regression test · Rollback.

## CHANGELOG — 2026-08-27 (compat & isolation round)
- ROOT CAUSE FIXED: niri-session's systemd PATH lacks ~/.local/bin → theme
  stamps silently never ran at Niri logins; an external config rewrite had
  also deleted the stamp line and declared shared Noctalia state. Restored
  with absolute-path spawns BEFORE noctalia, now stamp-log verified.
- Wallpaper isolation enforced: distinct seeds (Mango=lake/vibrant,
  Niri=pexels/builtin), single greeter_sync table each, auto_sync=false.
  Invariant battery added: verify.sh (28 checks, all passing).
- Cross-session Chromium stalls fixed via clean-stray-sessions hooked into
  ALL THREE session starters (scope-aware, never touches live scopes).
- KDE re-login hardening widened (ksplash + portal-kde teardown too).
- Identical keymap across all 3 sessions incl. new Mod+M =
  maximize-column (niri) / layout-cycle-to-monocle (mango) / Meta+M (KDE).
  Canonical table: keybinds.md. fcitx5 unified to XDG autostart only.
- Original/DWM toggle machinery purged completely per decision.

## CHANGELOG — 2026-08-27 (round 5: tarball incident + repo rescue)
- INCIDENT: v3.3 backed up the wrong path (rice-plan/backups vs actual
  rice-plan/multi-de/backups) -> 7.7GB of tarballs staged; .git grew to
  7.6GB; push would have been rejected (GitHub 100MB/file cap). Caught at
  the git pager BEFORE commit; pipeline killed (less swallows Ctrl+C).
- Script fixes: correct exclusion path, hard find -size +50M -delete guard
  over docs/plans, .seed.* temp cleanup, git reset before pull.
- Rescue executed: git reset, tarball copies removed, git gc --prune=now
  (.git 7.6GB -> 384KB), stray live .seed.XXXXXX deleted.
- Declarative Chrome policy CONFIRMED live (/etc/static/chromium symlink);
  niri.desktop Exec -> guarded wrapper CONFIRMED by health check.
- Remaining: one script re-run to commit + push the clean snapshot.

## CHANGELOG — 2026-08-27 (round 4: portability + v3.3 updater)

- update-system-and-push-v3.3.sh replaces v3.2: toggle machinery purge
  enforced (was crashing at step 11 + resurrecting purged files), full
  pipeline every run (flake update -> switch -> health -> snapshot -> push).
- Fixed v3.3 run-abort: trailing whitespace in copied rice-plan files killed
  git diff --check; now normalized on repo copies + warn-only.
- Snapshot widened: niri/, theme-profiles/, plasma-workspace/ hook,
  systemd/user gates, kwinrc (hot-corner fix), 5 isolation helpers,
  rice plan docs, auto-generated RESTORE-CURRENT.md (varied-hardware
  restore steps: GPU swaps, hostname, cachix trust, aesc requirement).
- Chromium default-browser policy made declarative in configuration.nix
  (environment.etc); manual /etc copy removed by script pre-switch.
- Portability verdict recorded: same-user (aesc) machines reproduce
  near-perfectly; wallpapers intentionally not snapshotted.

## CHANGELOG — 2026-08-27 (round 3: ExecStopPost retraction, wrapper v3)
- RETRACTED: unit drop-in ExecStopPost->niri-shutdown.target caused a
  circular wait (shutdown.target start queued inside the unit's own
  teardown) -> unit wedged in 'stop-post' 90s -> TimeoutStopSec kill ->
  every re-login saw is-active=true ("session already running") + black
  screen. Drop-in file deleted. LESSON: never start a conflicting target
  from within the unit it tears down; teardown belongs to the wrapper.
- Wrapper v3 (~/.local/bin/niri-session-guarded): hard invariant —
  never execs upstream niri-session until `is-active niri.service` =
  inactive. Escalation ladder: stop -> TERM -> 3s wait -> KILL -> cancel
  wedged transaction jobs -> reset-failed -> rm sockets -> 0.3s settle.
  Max 3 attempts, then FATAL abort with message (no blind exec).
- Live-system recovery performed: headless zombie niri (pid 14742, no
  DRM fds) SIGTERM'd; wedged jobs 321/351/322 cancelled; reset-failed;
  result: inactive + 0 jobs -> user logged into niri cleanly.
- Pending user action: sudo nixos-rebuild switch (patched niri.desktop
  w/ guarded wrapper is built & waiting: paiq06g32... in toplevel
  5jzj0fz0... closure).

## CHANGELOG — 2026-08-27 (round 2: zombie-compositor fix)
- ROOT CAUSE FIXED ("A niri session is already running"): greetd SIGTERMs the
  niri-session wrapper tree at session end (session-N.scope kill), so the
  script's post-exit lines never ran and niri.service survived as a zombie
  holding DRM/VT — log evidence: systemd[1] Killing 1567 (niri-session) +
  niri page-flip EACCES flood concurrent with later sessions.
- NEW layer: ~/.local/bin/niri-session-guarded is now the Exec target of
  niri.desktop (patched via dm-sessions-share in plasma.nix): kills any
  leftover compositor/unit of this UID, reset-failed, rm stale sockets,
  then execs real niri-session. Self-heals re-login deterministically.
- Unit drop-in (user-level, additive) added: niri.service ExecStopPost
  kicks niri-shutdown.target so app scopes always fall with the unit.
  Earlier systemd.user.services.<niri> approach REJECTED: it shadowed the
  packaged unit dropping ExecStart. Never define that service name here.
- Plasma bleed gated: 20 plasma-* user units get
  ConditionEnvironment=|XDG_CURRENT_DESKTOP=KDE drop-ins so kwin/plasma/
  kded6 etc stay inert in Mango/Niri sessions (journal showed them
  launching under Niri). Verified: condition fails as mango, passes as KDE.
- Minor: config.kdl polkit spawn fixed to absolute
  /run/current-system/sw/bin/lxqt-policykit-agent (binary name + PATH fix;
  journal had NotFound error). Chrome DefaultBrowserSettingEnabled=false
  policy confirmed live in /etc/chromium/policies/managed/.
- kitty terminal churn (~34 scopes) = user input during test, NOT a bug.
