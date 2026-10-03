import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { initialGeometry } from './geometry.js';

const MOVE_STEP = 80;

export default class TonelicoWindowRules extends Extension {
    enable() {
        this._settings = this.getSettings();
        this._pendingWindows = new Map();
        this._keybindings = [
            'focus-left', 'focus-right', 'focus-up', 'focus-down',
            'move-left', 'move-right', 'move-up', 'move-down',
        ];

        this._callbacks = {
            'focus-left': () => this._focusDirection(-1, 0),
            'focus-right': () => this._focusDirection(1, 0),
            'focus-up': () => this._focusDirection(0, -1),
            'focus-down': () => this._focusDirection(0, 1),
            'move-left': () => this._moveDirection(-1, 0),
            'move-right': () => this._moveDirection(1, 0),
            'move-up': () => this._moveDirection(0, -1),
            'move-down': () => this._moveDirection(0, 1),
        };

        for (const name of this._keybindings) {
            Main.wm.addKeybinding(
                name,
                this._settings,
                Meta.KeyBindingFlags.NONE,
                Shell.ActionMode.NORMAL,
                this._callbacks[name]
            );
        }

        this._displaySignal = global.display.connect('window-created', (_display, window) => {
            this._scheduleWindowGeometry(window);
        });
        // Mapping runs before the next paint, after Mutter has a real frame
        // size. Do this once, without a timer that moves an already visible app.
        this._mapSignal = global.window_manager.connect('map', (_wm, actor) => {
            const window = actor.meta_window;
            const pending = this._pendingWindows.get(window);
            if (!pending)
                return;
            const target = this._applyDefaultGeometry(window, pending.pointer);
            const settled = () => {
                const rect = window.get_frame_rect();
                return Math.abs(rect.x - target.x) <= 1 && Math.abs(rect.y - target.y) <= 1 &&
                    Math.abs(rect.width - target.width) <= 1 && Math.abs(rect.height - target.height) <= 1;
            };
            if (!target || settled()) {
                this._finishWindowGeometry(window);
                return;
            }

            // Wayland applies a resize after the client acknowledges its
            // configure. Keep the initial actor hidden for that round trip,
            // so its first painted frame is already at the final geometry.
            pending.actor = actor;
            actor.hide();
            const onGeometryChanged = () => {
                if (settled())
                    this._finishWindowGeometry(window);
            };
            pending.sizeSignal = window.connect('size-changed', onGeometryChanged);
            pending.positionSignal = window.connect('position-changed', onGeometryChanged);
            // An unresponsive app must still become visible. This is only a
            // visibility fallback; it never schedules another move or resize.
            pending.timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 200, () => {
                pending.timeoutId = null;
                this._finishWindowGeometry(window);
                return GLib.SOURCE_REMOVE;
            });
        });
    }

    disable() {
        if (this._displaySignal !== undefined) {
            global.display.disconnect(this._displaySignal);
            this._displaySignal = undefined;
        }

        if (this._mapSignal !== undefined) {
            global.window_manager.disconnect(this._mapSignal);
            this._mapSignal = undefined;
        }

        for (const window of this._pendingWindows.keys())
            this._finishWindowGeometry(window);
        this._pendingWindows.clear();

        for (const name of this._keybindings ?? [])
            Main.wm.removeKeybinding(name);

        this._settings = null;
        this._callbacks = null;
        this._keybindings = null;
    }

    _scheduleWindowGeometry(window) {
        if (window.get_window_type() !== Meta.WindowType.NORMAL ||
            window.get_transient_for() !== null)
            return;

        const unmanagedSignal = window.connect('unmanaged', () => {
            this._finishWindowGeometry(window, false);
        });

        this._pendingWindows.set(window, { pointer: global.get_pointer(), unmanagedSignal });
    }

    _finishWindowGeometry(window, show = true) {
        const pending = this._pendingWindows.get(window);
        if (!pending)
            return;
        this._pendingWindows.delete(window);
        if (pending.timeoutId)
            GLib.source_remove(pending.timeoutId);
        for (const id of [pending.unmanagedSignal, pending.sizeSignal, pending.positionSignal]) {
            if (id)
                window.disconnect(id);
        }
        if (show)
            pending.actor?.show();
    }

    _applyDefaultGeometry(window, pointer) {
        if (window.get_window_type() !== Meta.WindowType.NORMAL ||
            window.get_transient_for() !== null ||
            window.is_fullscreen() ||
            !window.allows_resize() || !window.allows_move())
            return;

        if (window.get_maximize_flags() !== 0)
            window.unmaximize(Meta.MaximizeFlags.BOTH);

        let monitor = Main.layoutManager.monitors.findIndex(area =>
            pointer[0] >= area.x && pointer[0] < area.x + area.width &&
            pointer[1] >= area.y && pointer[1] < area.y + area.height);
        if (monitor < 0)
            monitor = window.get_monitor();
        if (monitor < 0)
            monitor = global.display.get_current_monitor();
        if (monitor < 0)
            return;

        if (window.get_monitor() !== monitor)
            window.move_to_monitor(monitor);

        const area = window.get_work_area_for_monitor(monitor);
        const rect = window.get_frame_rect();
        const [hasMinimum, minWidth, minHeight] = window.get_min_size();
        const minimum = hasMinimum
            ? window.client_rect_to_frame_rect(new Mtk.Rectangle({ x: 0, y: 0, width: minWidth, height: minHeight }))
            : {};
        const occupied = global.display.get_tab_list(Meta.TabList.NORMAL, window.get_workspace())
            .filter(other => other !== window && !other.minimized &&
                other.get_monitor() === monitor && other.get_window_type() === Meta.WindowType.NORMAL)
            .map(other => other.get_frame_rect());
        const { x, y, width, height } = initialGeometry(area, pointer, rect, occupied, minimum);

        window.move_resize_frame(false, x, y, width, height);
        return { x, y, width, height };
    }

    _focusDirection(dx, dy) {
        const active = global.display.get_focus_window();
        if (!active || active.get_window_type() !== Meta.WindowType.NORMAL)
            return;

        const activeRect = active.get_frame_rect();
        const activeX = activeRect.x + activeRect.width / 2;
        const activeY = activeRect.y + activeRect.height / 2;
        const workspace = active.get_workspace();
        let best = null;
        let bestScore = Number.POSITIVE_INFINITY;

        for (const candidate of global.display.get_tab_list(Meta.TabList.NORMAL, workspace)) {
            if (candidate === active ||
                candidate.get_window_type() !== Meta.WindowType.NORMAL ||
                candidate.minimized)
                continue;

            const rect = candidate.get_frame_rect();
            const deltaX = rect.x + rect.width / 2 - activeX;
            const deltaY = rect.y + rect.height / 2 - activeY;
            const primary = dx !== 0 ? deltaX * dx : deltaY * dy;
            if (primary <= 0)
                continue;

            const cross = dx !== 0 ? Math.abs(deltaY) : Math.abs(deltaX);
            const score = primary + cross * 1.5;
            if (score < bestScore) {
                best = candidate;
                bestScore = score;
            }
        }

        best?.activate(global.get_current_time());
    }

    _moveDirection(dx, dy) {
        const window = global.display.get_focus_window();
        if (!window || window.get_window_type() !== Meta.WindowType.NORMAL ||
            !window.allows_move() || window.is_fullscreen() || window.get_maximize_flags() !== 0)
            return;

        let monitor = window.get_monitor();
        if (monitor < 0)
            monitor = global.display.get_current_monitor();

        const area = window.get_work_area_for_monitor(monitor);
        const rect = window.get_frame_rect();
        const maxX = Math.max(area.x, area.x + area.width - rect.width);
        const maxY = Math.max(area.y, area.y + area.height - rect.height);
        const x = Math.max(area.x, Math.min(maxX, rect.x + dx * MOVE_STEP));
        const y = Math.max(area.y, Math.min(maxY, rect.y + dy * MOVE_STEP));

        window.move_resize_frame(true, x, y, rect.width, rect.height);
    }
}
