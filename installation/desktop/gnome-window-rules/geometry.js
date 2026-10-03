// Pure geometry policy; coordinates and sizes are GNOME logical pixels.
export function initialGeometry(area, pointer, rect, occupied = [], minimum = {}) {
    const capWidth = Math.min(1050, Math.floor(area.width * 0.75));
    const capHeight = Math.min(638, Math.floor(area.height * 0.75));
    const width = Math.max(minimum.width ?? 1, Math.min(rect.width, capWidth));
    const height = Math.max(minimum.height ?? 1, Math.min(rect.height, capHeight));
    const clampX = x => Math.round(Math.max(area.x,
        Math.min(area.x + Math.max(0, area.width - width), x)));
    const clampY = y => Math.round(Math.max(area.y,
        Math.min(area.y + Math.max(0, area.height - height), y)));
    const x = clampX(pointer[0] - width / 2);
    const y = clampY(pointer[1] - height / 2);

    // Keep the cursor as the center unless another window would have an
    // indistinguishable top-left corner. A small cascade exposes its titlebar.
    const offsets = [[0, 0], [40, 40], [-40, 40], [40, -40], [-40, -40],
        [80, 80], [-80, 80], [80, -80], [-80, -80]];
    for (const [dx, dy] of offsets) {
        const nextX = clampX(x + dx);
        const nextY = clampY(y + dy);
        if (!occupied.some(other => Math.abs(other.x - nextX) < 32 &&
            Math.abs(other.y - nextY) < 32))
            return { x: nextX, y: nextY, width, height };
    }
    return { x, y, width, height };
}
