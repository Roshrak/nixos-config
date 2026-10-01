import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const DEFAULT_WIDTH = 1050;
const DEFAULT_HEIGHT = 638;
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
    }

    disable() {
        if (this._displaySignal !== undefined) {
            global.display.disconnect(this._displaySignal);
            this._displaySignal = undefined;
        }

        for (const [window, pending] of this._pendingWindows) {
            GLib.source_remove(pending.timeoutId);
            window.disconnect(pending.unmanagedSignal);
        }
        this._pendingWindows.clear();

        for (const name of this._keybindings ?? [])
            Main.wm.removeKeybinding(name);

        this._settings = null;
        this._callbacks = null;
        this._keybindings = null;
    }

    _scheduleWindowGeometry(window) {
        if (window.get_window_type() !== Meta.WindowType.NORMAL)
            return;

        const unmanagedSignal = window.connect('unmanaged', () => {
            const pending = this._pendingWindows.get(window);
            if (!pending)
                return;

            GLib.source_remove(pending.timeoutId);
            this._pendingWindows.delete(window);
        });

        const timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 650, () => {
            this._pendingWindows.delete(window);
            window.disconnect(unmanagedSignal);
            this._applyDefaultGeometry(window);
            return GLib.SOURCE_REMOVE;
        });

        this._pendingWindows.set(window, { timeoutId, unmanagedSignal });
    }

    _applyDefaultGeometry(window) {
        if (window.get_window_type() !== Meta.WindowType.NORMAL ||
            window.get_transient_for() !== null ||
            window.is_fullscreen() ||
            !window.allows_resize())
            return;

        if (window.get_maximize_flags() !== 0)
            window.unmaximize(Meta.MaximizeFlags.BOTH);

        let monitor = window.get_monitor();
        if (monitor < 0)
            monitor = global.display.get_current_monitor();

        const area = window.get_work_area_for_monitor(monitor);
        const width = Math.min(DEFAULT_WIDTH, Math.floor(area.width * 0.75));
        const height = Math.min(DEFAULT_HEIGHT, Math.floor(area.height * 0.75));
        const x = Math.round(area.x + (area.width - width) / 2);
        const y = Math.round(area.y + (area.height - height) / 2);

        window.move_resize_frame(false, x, y, width, height);
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
                candidate.is_minimized())
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
        if (!window || window.get_window_type() !== Meta.WindowType.NORMAL || !window.allows_move())
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
