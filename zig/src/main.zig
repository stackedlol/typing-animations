//! pastel.zig: a small text editor written in Zig, set in Manrope on a flat page.
//!
//! Everything runs here as wasm32-freestanding: the text buffer, editing and undo,
//! proportional word-wrapped layout, Zig syntax highlighting, a software renderer and
//! every effect. The effects live in an ASCII field after the ascii-sharks renderer: ink
//! is deposited into a grid of cells, each cell shows a glyph from a density ramp, and a
//! Bayer dither picks between neighbouring glyphs. Typing sends ripples and little fish
//! with wakes through it, deleting dissolves text down the ramp, jumps leave a streak.
//! On top, ff-tracking lock-ons bracket finished words and landing spots.
//! The page around it only forwards input and shows the pixels. No std.

// ───────────────────────────── constants ─────────────────────────────

// Manrope 500 @ 56px: 95 advances (u16, 1/16 px), then 95 glyph cells of 92×96 alpha.
const atlas = @embedFile("atlas.bin");
const NG: usize = 95;
const GOFF: usize = NG * 2;
const GW: i32 = 92;
const GH: i32 = 96;
const PAD: f32 = 10; // glyph origin inside its cell
const BASE: f32 = 70; // baseline, from the row top
const MID: f32 = 55; // optical centre of a lowercase letter, from the row top
const LH: f32 = 96; // line height, device px (the page renders at 2× css px)
const TOP: f32 = 200;

// The ASCII field: Manrope 700 @ 22px in 14×24 cells, a density ramp after ascii-sharks' skin ramp.
const ramp = @embedFile("ramp.bin");
const RAMP_N: usize = 11; // . , : ; t % S X 8 # @
const CWc: i32 = 14;
const CHc: i32 = 24;
const BAYER = [16]f32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

const MAXW: usize = 3200;
const MAXH: usize = 2000;
const MAXT: usize = 1 << 20;
const MAXR: usize = 1 << 17;
const FW: usize = MAXW / 14 + 2;
const FH: usize = MAXH / 24 + 2;

const Col = [3]u32;
const Theme = struct {
    bg: Col,
    ink: Col,
    hl: [4]Col, // highlighter marks: mint, sky, rose, lavender
    pop: [4]Col, // the same hues, strong enough for a caret or a glyph in the field
    box: Col, // ff-tracking, settled
    lock: Col, // ff-tracking, while it locks
};
const LIGHT = Theme{
    .bg = .{ 255, 255, 255 },
    .ink = .{ 26, 27, 34 },
    .hl = .{ .{ 196, 238, 208 }, .{ 200, 222, 248 }, .{ 252, 204, 202 }, .{ 224, 212, 250 } },
    .pop = .{ .{ 88, 190, 128 }, .{ 92, 152, 226 }, .{ 236, 112, 108 }, .{ 150, 118, 226 } },
    .box = .{ 28, 28, 30 },
    .lock = .{ 255, 64, 52 },
};
const DARK = Theme{
    .bg = .{ 0, 0, 0 },
    .ink = .{ 236, 235, 230 },
    .hl = .{ .{ 168, 220, 181 }, .{ 166, 200, 234 }, .{ 240, 163, 163 }, .{ 198, 179, 232 } },
    .pop = .{ .{ 168, 220, 181 }, .{ 166, 200, 234 }, .{ 240, 163, 163 }, .{ 198, 179, 232 } },
    .box = .{ 236, 235, 230 },
    .lock = .{ 255, 92, 80 },
};
var th: *const Theme = &LIGHT;
var dark = false;

// ───────────────────────────── state ─────────────────────────────

var fb: [MAXW * MAXH * 4]u8 = undefined;
var W: i32 = 0;
var H: i32 = 0;

var text: [MAXT]u8 = undefined;
var tlen: usize = 0;
var scratch: [MAXT]u8 = undefined;

var rowStart: [MAXR]u32 = undefined;
var rowLen: [MAXR]u32 = undefined;
var rowLine: [MAXR]u32 = undefined;
var rowFirst: [MAXR]bool = undefined;
var nrows: usize = 0;
var textX: f32 = 200;
var avail: f32 = 1200;

var cur: usize = 0;
var anchor: usize = 0;
var goalX: f32 = -1;
var focused: bool = true;
var dragging: bool = false;

var scroll: f32 = 0;
var scrollGoal: f32 = 0;
var clock: f32 = 0;
var changedFlag: bool = false;
var wordCount: u32 = 0;
var rng: u32 = 0x9e3779b9;

const Op = struct { pos: u32, del_off: u32, del_len: u32, ins_off: u32, ins_len: u32, before: u32, after: u32, group: u32 };
var ops: [4096]Op = undefined;
var nops: usize = 0;
var opTop: usize = 0;
var arena: [4 << 20]u8 = undefined;
var arenaLen: usize = 0;
var group: u32 = 0;
var lastKind: u8 = 0;
var lastEditAt: f32 = -10;
var lastEditEnd: usize = 0;
var recording: bool = true;

// ───────────────────────────── helpers ─────────────────────────────

fn f(v: anytype) f32 {
    return @floatFromInt(v);
}
fn clampf(v: f32, a: f32, b: f32) f32 {
    return @max(a, @min(b, v));
}
fn toI(v: f32) i32 {
    return @intFromFloat(@floor(clampf(v, -1e8, 1e8)));
}
fn rand() f32 {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return f(rng >> 8) / 16777216.0;
}
fn rnd(a: f32, b: f32) f32 {
    return a + (b - a) * rand();
}
fn isWord(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}
fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
fn gi(c: u8) usize {
    return if (c >= 32 and c < 127) c - 32 else '?' - 32;
}
fn adv(c: u8) f32 {
    const i = gi(c);
    const v: u32 = @as(u32, atlas[i * 2]) | (@as(u32, atlas[i * 2 + 1]) << 8);
    // Manrope's space is tight for code; open it up a little
    return if (c == ' ') f(v) / 16.0 * 1.35 else f(v) / 16.0;
}
fn mix(a: Col, b: Col, k: f32) Col {
    const t = clampf(k, 0, 1);
    return .{
        @intFromFloat(f(a[0]) + (f(b[0]) - f(a[0])) * t),
        @intFromFloat(f(a[1]) + (f(b[1]) - f(a[1])) * t),
        @intFromFloat(f(a[2]) + (f(b[2]) - f(a[2])) * t),
    };
}

// ───────────────────────────── dirty regions ─────────────────────────────

const Rect = struct {
    x0: i32 = 1 << 30,
    y0: i32 = 1 << 30,
    x1: i32 = -(1 << 30),
    y1: i32 = -(1 << 30),
    fn add(r: *Rect, x0: i32, y0: i32, x1: i32, y1: i32) void {
        r.x0 = @min(r.x0, x0);
        r.y0 = @min(r.y0, y0);
        r.x1 = @max(r.x1, x1);
        r.y1 = @max(r.y1, y1);
    }
    fn addf(r: *Rect, x0: f32, y0: f32, x1: f32, y1: f32) void {
        r.add(toI(x0), toI(y0), toI(x1) + 1, toI(y1) + 1);
    }
    fn merge(r: *Rect, o: Rect) void {
        if (o.x1 > o.x0) r.add(o.x0, o.y0, o.x1, o.y1);
    }
    fn empty(r: Rect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }
};
var pending: Rect = .{};
var prevFx: Rect = .{};
var full: bool = true;
var out: Rect = .{};
var cx0: i32 = 0;
var cy0: i32 = 0;
var cx1: i32 = 0;
var cy1: i32 = 0;

// ───────────────────────────── pixels ─────────────────────────────

inline fn blend(x: i32, y: i32, c: Col, a: u32) void {
    const i: usize = (@as(usize, @intCast(y)) * @as(usize, @intCast(W)) + @as(usize, @intCast(x))) * 4;
    const ia = 255 - a;
    fb[i] = @intCast((c[0] * a + @as(u32, fb[i]) * ia + 127) / 255);
    fb[i + 1] = @intCast((c[1] * a + @as(u32, fb[i + 1]) * ia + 127) / 255);
    fb[i + 2] = @intCast((c[2] * a + @as(u32, fb[i + 2]) * ia + 127) / 255);
}
inline fn blendf(x: i32, y: i32, c: Col, a: f32) void {
    if (a > 0.004) blend(x, y, c, @intFromFloat(@min(a * 255, 255)));
}

fn fillRect(x0: f32, y0: f32, x1: f32, y1: f32, c: Col, alpha: f32) void {
    const xs = @max(toI(x0), cx0);
    const xe = @min(toI(x1), cx1);
    const ys = @max(toI(y0), cy0);
    const ye = @min(toI(y1), cy1);
    const a: u32 = @intFromFloat(clampf(alpha, 0, 1) * 255);
    if (a == 0) return;
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) blend(x, y, c, a);
    }
}

// a rounded rectangle, antialiased: the highlighter marks behind tokens on white
fn roundRect(x0: f32, y0: f32, x1: f32, y1: f32, r: f32, c: Col, alpha: f32) void {
    const xs = @max(toI(x0 - 1), cx0);
    const xe = @min(toI(x1 + 2), cx1);
    const ys = @max(toI(y0 - 1), cy0);
    const ye = @min(toI(y1 + 2), cy1);
    const hx = (x1 - x0) / 2;
    const hy = (y1 - y0) / 2;
    const mx = (x0 + x1) / 2;
    const my = (y0 + y1) / 2;
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) {
            const qx = @abs(f(x) + 0.5 - mx) - (hx - r);
            const qy = @abs(f(y) + 0.5 - my) - (hy - r);
            const ox = @max(qx, 0);
            const oy = @max(qy, 0);
            const d = @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
            blendf(x, y, c, clampf(0.5 - d, 0, 1) * alpha);
        }
    }
}

fn glyph(ch: u8, penX: f32, top: f32, c: Col, alpha: f32) void {
    if (ch <= 32 or ch > 126) return;
    const base: usize = GOFF + gi(ch) * @as(usize, @intCast(GW * GH));
    const x0 = toI(penX - PAD + 0.5);
    const y0 = toI(top);
    const xs = @max(x0, cx0);
    const xe = @min(x0 + GW, cx1);
    const ys = @max(y0, cy0);
    const ye = @min(y0 + GH, cy1);
    const am: u32 = @intFromFloat(clampf(alpha, 0, 1) * 256);
    var y = ys;
    while (y < ye) : (y += 1) {
        const row = base + @as(usize, @intCast((y - y0) * GW));
        var x = xs;
        while (x < xe) : (x += 1) {
            const a: u32 = atlas[row + @as(usize, @intCast(x - x0))];
            if (a != 0) blend(x, y, c, @min((a * am) >> 8, 255));
        }
    }
}

// a glyph stretched and squashed about its baseline, bilinear: freshly typed letters stamp in
fn glyphStamp(ch: u8, penX: f32, top: f32, sx: f32, sy: f32, dy: f32, c: Col, alpha: f32) void {
    if (ch <= 32 or ch > 126 or sx < 0.05 or sy < 0.05) return;
    const base: usize = GOFF + gi(ch) * @as(usize, @intCast(GW * GH));
    const a = adv(ch);
    // anchored exactly where glyph() would put it, so a letter at rest never hops
    const cx = @floor(penX - PAD + 0.5) + PAD + a / 2;
    const by = @floor(top) + BASE + dy;
    const acx = PAD + a / 2;
    const xs = @max(toI(cx - (acx + 2) * sx), cx0);
    const xe = @min(toI(cx + (f(GW) - acx + 2) * sx), cx1);
    const ys = @max(toI(by - (BASE + 2) * sy), cy0);
    const ye = @min(toI(by + (f(GH) - BASE + 2) * sy), cy1);
    const gw: usize = @intCast(GW);
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) {
            const u = (f(x) + 0.5 - cx) / sx + acx - 0.5;
            const v = (f(y) + 0.5 - by) / sy + BASE - 0.5;
            if (u < 0 or v < 0 or u >= f(GW - 1) or v >= f(GH - 1)) continue;
            const ui: usize = @intFromFloat(u);
            const vi: usize = @intFromFloat(v);
            const fu = u - f(ui);
            const fv = v - f(vi);
            const i = base + vi * gw + ui;
            const t0 = f(atlas[i]) + (f(atlas[i + 1]) - f(atlas[i])) * fu;
            const t1 = f(atlas[i + gw]) + (f(atlas[i + gw + 1]) - f(atlas[i + gw])) * fu;
            blendf(x, y, c, (t0 + (t1 - t0) * fv) / 255.0 * alpha);
        }
    }
}

// a ring of page colour around a glyph, so the field behind never cuts through a letter
fn halo(ch: u8, penX: f32, top: f32) void {
    const o = [8][2]f32{ .{ -3, 0 }, .{ 3, 0 }, .{ 0, -3 }, .{ 0, 3 }, .{ -2, -2 }, .{ 2, -2 }, .{ -2, 2 }, .{ 2, 2 } };
    for (o) |d| glyph(ch, penX + d[0], top + d[1], th.bg, 1);
}

fn seg(ax: f32, ay: f32, bx: f32, by: f32, r: f32, c: Col, alpha: f32) void {
    const xs = @max(toI(@min(ax, bx) - r - 1), cx0);
    const xe = @min(toI(@max(ax, bx) + r + 2), cx1);
    const ys = @max(toI(@min(ay, by) - r - 1), cy0);
    const ye = @min(toI(@max(ay, by) + r + 2), cy1);
    const vx = bx - ax;
    const vy = by - ay;
    const l2 = @max(vx * vx + vy * vy, 1e-4);
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) {
            const qx = f(x) + 0.5 - ax;
            const qy = f(y) + 0.5 - ay;
            const t = clampf((qx * vx + qy * vy) / l2, 0, 1);
            const dx = qx - vx * t;
            const dy = qy - vy * t;
            blendf(x, y, c, clampf(r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1) * alpha);
        }
    }
}

// a convex polygon: the caret
fn poly(p: []const [2]f32, c: Col, alpha: f32) void {
    const n = p.len;
    var area: f32 = 0;
    var mnx: f32 = 1e9;
    var mny: f32 = 1e9;
    var mxx: f32 = -1e9;
    var mxy: f32 = -1e9;
    for (0..n) |i| {
        const j = (i + 1) % n;
        area += p[i][0] * p[j][1] - p[j][0] * p[i][1];
        mnx = @min(mnx, p[i][0]);
        mny = @min(mny, p[i][1]);
        mxx = @max(mxx, p[i][0]);
        mxy = @max(mxy, p[i][1]);
    }
    const sgn: f32 = if (area < 0) -1 else 1;
    const xs = @max(toI(mnx - 1), cx0);
    const xe = @min(toI(mxx + 2), cx1);
    const ys = @max(toI(mny - 1), cy0);
    const ye = @min(toI(mxy + 2), cy1);
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) {
            const px = f(x) + 0.5;
            const py = f(y) + 0.5;
            var dmax: f32 = -1e9;
            for (0..n) |i| {
                const j = (i + 1) % n;
                const ex = p[j][0] - p[i][0];
                const ey = p[j][1] - p[i][1];
                const l = @max(@sqrt(ex * ex + ey * ey), 1e-4);
                dmax = @max(dmax, sgn * ((px - p[i][0]) * ey - (py - p[i][1]) * ex) / l);
            }
            blendf(x, y, c, clampf(0.5 - dmax, 0, 1) * alpha);
        }
    }
}

// ───────────────────────────── the ASCII field ─────────────────────────────
// After ascii-sharks: effects never draw pixels directly. They deposit ink into a grid of
// cells; ink fades every frame, and each cell shows a glyph from the density ramp, dithered
// against a 4×4 Bayer matrix so the field steps smoothly from a stray dot to a solid @.

var fieldI: [FW * FH]f32 = undefined;
var fieldH: [FW * FH]u8 = undefined;
var fw: usize = 1;
var fh: usize = 1;
// the cells with ink in them, so neither the fade nor the redraw walks the whole grid
var ax0: usize = 0;
var ay0: usize = 0;
var ax1: usize = 0;
var ay1: usize = 0;
var prevField: Rect = .{};

fn deposit(cx: i32, cy: i32, v: f32, hue: u8) void {
    if (cx < 0 or cy < 0 or cx >= @as(i32, @intCast(fw)) or cy >= @as(i32, @intCast(fh)) or v <= 0.02) return;
    const x: usize = @intCast(cx);
    const y: usize = @intCast(cy);
    const i = y * fw + x;
    if (v > fieldI[i]) {
        fieldI[i] = @min(v, 1);
        fieldH[i] = hue;
    }
    if (ax1 <= ax0) {
        ax0 = x;
        ay0 = y;
        ax1 = x + 1;
        ay1 = y + 1;
    } else {
        ax0 = @min(ax0, x);
        ay0 = @min(ay0, y);
        ax1 = @max(ax1, x + 1);
        ay1 = @max(ay1, y + 1);
    }
}
fn cellOf(px: f32, py: f32) [2]i32 {
    return .{ toI(px / f(CWc)), toI(py / f(CHc)) };
}
// a soft blob, in screen px
fn blob(px: f32, py: f32, r: f32, v: f32, hue: u8) void {
    const a = cellOf(px - r, py - r);
    const b = cellOf(px + r, py + r);
    var y = a[1];
    while (y <= b[1]) : (y += 1) {
        var x = a[0];
        while (x <= b[0]) : (x += 1) {
            const dx = (f(x) + 0.5) * f(CWc) - px;
            const dy = (f(y) + 0.5) * f(CHc) - py;
            const k = 1 - @sqrt(dx * dx + dy * dy) / r;
            if (k > 0) deposit(x, y, v * @sqrt(k), hue);
        }
    }
}
// a ring, flattened like a ripple seen across the page
fn ring(px: f32, py: f32, r: f32, w: f32, v: f32, hue: u8) void {
    const ry = r * 0.55;
    const a = cellOf(px - r - w, py - ry - w);
    const b = cellOf(px + r + w, py + ry + w);
    var y = a[1];
    while (y <= b[1]) : (y += 1) {
        var x = a[0];
        while (x <= b[0]) : (x += 1) {
            const dx = (f(x) + 0.5) * f(CWc) - px;
            const dy = ((f(y) + 0.5) * f(CHc) - py) / 0.55;
            const k = 1 - @abs(@sqrt(dx * dx + dy * dy) - r) / w;
            if (k > 0) deposit(x, y, v * k, hue);
        }
    }
}
fn line(ax: f32, ay: f32, bx: f32, by: f32, v: f32, hue: u8) void {
    const dx = bx - ax;
    const dy = by - ay;
    const n: usize = @intFromFloat(@max(1, @sqrt(dx * dx + dy * dy) / 8));
    for (0..n + 1) |i| {
        const t = f(i) / f(n);
        const c = cellOf(ax + dx * t, ay + dy * t);
        deposit(c[0], c[1], v, hue);
    }
}

fn fadeField(dt: f32) void {
    if (ax1 <= ax0) return;
    const k = @exp(-dt * 3.4);
    var nx0: usize = fw;
    var ny0: usize = fh;
    var nx1: usize = 0;
    var ny1: usize = 0;
    var y = ay0;
    while (y < ay1) : (y += 1) {
        var x = ax0;
        while (x < ax1) : (x += 1) {
            const i = y * fw + x;
            if (fieldI[i] == 0) continue;
            fieldI[i] *= k;
            if (fieldI[i] < 0.025) {
                fieldI[i] = 0;
                continue;
            }
            nx0 = @min(nx0, x);
            ny0 = @min(ny0, y);
            nx1 = @max(nx1, x + 1);
            ny1 = @max(ny1, y + 1);
        }
    }
    if (nx1 <= nx0) {
        ax0 = 0;
        ax1 = 0;
        ay0 = 0;
        ay1 = 0;
    } else {
        ax0 = nx0;
        ay0 = ny0;
        ax1 = nx1;
        ay1 = ny1;
    }
}

fn fieldRect() Rect {
    var r: Rect = .{};
    if (ax1 > ax0) r.add(@as(i32, @intCast(ax0)) * CWc, @as(i32, @intCast(ay0)) * CHc, @as(i32, @intCast(ax1)) * CWc, @as(i32, @intCast(ay1)) * CHc);
    return r;
}

fn drawField() void {
    if (ax1 <= ax0) return;
    const xs: usize = @intCast(@max(@as(i32, @intCast(ax0)), @divFloor(cx0, CWc)));
    const xe: usize = @intCast(@max(0, @min(@as(i32, @intCast(ax1)), @divFloor(cx1 + CWc - 1, CWc))));
    const ys: usize = @intCast(@max(@as(i32, @intCast(ay0)), @divFloor(cy0, CHc)));
    const ye: usize = @intCast(@max(0, @min(@as(i32, @intCast(ay1)), @divFloor(cy1 + CHc - 1, CHc))));
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) {
            const v = fieldI[y * fw + x];
            if (v <= 0) continue;
            // the ramp, dithered: the Bayer threshold decides between neighbouring glyphs
            const q = v * f(RAMP_N);
            var idx: usize = @intFromFloat(@floor(q));
            const b = (BAYER[(y & 3) * 4 + (x & 3)] + 0.5) / 16;
            if (q - f(idx) > b) idx += 1;
            if (idx == 0) continue;
            idx = @min(idx, RAMP_N) - 1;
            cellGlyph(idx, @as(i32, @intCast(x)) * CWc, @as(i32, @intCast(y)) * CHc, th.pop[fieldH[y * fw + x]], 0.35 + 0.45 * v);
        }
    }
}
fn cellGlyph(idx: usize, x0: i32, y0: i32, c: Col, alpha: f32) void {
    const base = idx * @as(usize, @intCast(CWc * CHc));
    const am: u32 = @intFromFloat(clampf(alpha, 0, 1) * 256);
    const xs = @max(x0, cx0);
    const xe = @min(x0 + CWc, cx1);
    const ys = @max(y0, cy0);
    const ye = @min(y0 + CHc, cy1);
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) {
            const a: u32 = ramp[base + @as(usize, @intCast((y - y0) * CWc + (x - x0)))];
            if (a != 0) blend(x, y, c, @min((a * am) >> 8, 255));
        }
    }
}

// the things that write into the field
const Ripple = struct { x: f32, y: f32, t: f32, power: f32, hue: u8 };
var ripples: [64]Ripple = undefined;
var nrip: usize = 0;
// little fish, after ascii-sharks: they swim off on a curve and leave a wake of glyphs
const Fish = struct { x: f32, y: f32, vx: f32, vy: f32, turn: f32, t: f32, life: f32, hue: u8 };
var fish: [512]Fish = undefined;
var nfish: usize = 0;
const Streak = struct { ax: f32, ay: f32, bx: f32, by: f32, t: f32, hue: u8 };
var streaks: [16]Streak = undefined;
var nstreak: usize = 0;

fn splash(x: f32, y: f32, power: f32, nf: usize, hue: u8) void {
    blob(x, y, 26 * power, 0.95, hue);
    if (nrip < ripples.len) {
        ripples[nrip] = .{ .x = x, .y = y, .t = 0, .power = power, .hue = hue };
        nrip += 1;
    }
    var i: usize = 0;
    while (i < nf and nfish < fish.len) : (i += 1) {
        const a = rnd(0, 6.283);
        const s = rnd(220, 520) * power;
        fish[nfish] = .{ .x = x, .y = y, .vx = @cos(a) * s, .vy = @sin(a) * s * 0.6, .turn = rnd(-5, 5), .t = 0, .life = rnd(0.35, 0.7), .hue = if (rand() < 0.6) hue else @intFromFloat(rnd(0, 3.99)) };
        nfish += 1;
    }
}

fn stepField(dt: f32) void {
    fadeField(dt);
    var i: usize = 0;
    while (i < nrip) {
        var r = &ripples[i];
        r.t += dt;
        const life: f32 = 0.42;
        if (r.t > life) {
            ripples[i] = ripples[nrip - 1];
            nrip -= 1;
            continue;
        }
        const k = r.t / life;
        ring(r.x, r.y, 10 + (1 - (1 - k) * (1 - k)) * 120 * r.power, 16, 0.85 * (1 - k), r.hue);
        i += 1;
    }
    i = 0;
    while (i < nfish) {
        var p = &fish[i];
        p.t += dt;
        if (p.t > p.life) {
            fish[i] = fish[nfish - 1];
            nfish -= 1;
            continue;
        }
        const ox = p.x;
        const oy = p.y;
        const a = p.turn * dt;
        const vx = p.vx * @cos(a) - p.vy * @sin(a);
        p.vy = p.vx * @sin(a) + p.vy * @cos(a);
        p.vx = vx;
        const drag = @exp(-2.2 * dt);
        p.vx *= drag;
        p.vy *= drag;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        line(ox, oy, p.x, p.y, 0.9 * (1 - p.t / p.life), p.hue);
        i += 1;
    }
    i = 0;
    while (i < nstreak) {
        var s = &streaks[i];
        const t0 = s.t;
        s.t += dt;
        const k0 = clampf(t0 / 0.22, 0, 1);
        const k1 = clampf(s.t / 0.22, 0, 1);
        line(s.ax + (s.bx - s.ax) * k0, s.ay + (s.by - s.ay) * k0, s.ax + (s.bx - s.ax) * k1, s.ay + (s.by - s.ay) * k1, 1, s.hue);
        if (s.t > 0.24) {
            streaks[i] = streaks[nstreak - 1];
            nstreak -= 1;
        } else i += 1;
    }
}

// ───────────────────────────── ff-tracking ─────────────────────────────
// The look of ff-tracking (Mustafa Saraç, MIT): corner
// brackets that snap in as they lock on, a diagonal hatch while they lock, and a tag in a
// 3×5 pixel font with the letters knocked out of a filled pill.

const PIX = [_]struct { c: u8, bits: u16 }{
    .{ .c = '0', .bits = 31599 }, .{ .c = '1', .bits = 11415 }, .{ .c = '2', .bits = 29671 }, .{ .c = '3', .bits = 29647 },
    .{ .c = '4', .bits = 23497 }, .{ .c = '5', .bits = 31183 }, .{ .c = '6', .bits = 31215 }, .{ .c = '7', .bits = 29257 },
    .{ .c = '8', .bits = 31727 }, .{ .c = '9', .bits = 31695 }, .{ .c = 'X', .bits = 23213 }, .{ .c = 'Y', .bits = 23186 },
    .{ .c = ':', .bits = 1040 },  .{ .c = ' ', .bits = 0 },     .{ .c = '.', .bits = 2 },
};
fn pixBits(c: u8) ?u16 {
    for (PIX) |p| if (p.c == c) return p.bits;
    return null;
}

fn brackets(x0: f32, y0: f32, x1: f32, y1: f32, c: Col, alpha: f32, hatch: bool) void {
    const l = @round(x0);
    const t = @round(y0);
    const r = @round(x1);
    const b = @round(y1);
    const arm = @max(8, @round(@min(@min(r - l, b - t), 80) * 0.28));
    const k: f32 = 2; // one css px
    fillRect(l, t, l + arm, t + k, c, alpha);
    fillRect(l, t, l + k, t + arm, c, alpha);
    fillRect(r - arm, t, r, t + k, c, alpha);
    fillRect(r - k, t, r, t + arm, c, alpha);
    fillRect(l, b - k, l + arm, b, c, alpha);
    fillRect(l, b - arm, l + k, b, c, alpha);
    fillRect(r - arm, b - k, r, b, c, alpha);
    fillRect(r - k, b - arm, r, b, c, alpha);
    if (!hatch) return;
    const xs = @max(toI(l), cx0);
    const xe = @min(toI(r), cx1);
    const ys = @max(toI(t), cy0);
    const ye = @min(toI(b), cy1);
    const a: u32 = @intFromFloat(clampf(alpha * 0.12, 0, 1) * 255);
    var y = ys;
    while (y < ye) : (y += 1) {
        var x = xs;
        while (x < xe) : (x += 1) if (((x - y) & 7) < 2) blend(x, y, c, a);
    }
}

fn tag(x: f32, y: f32, s: []const u8, c: Col, alpha: f32) void {
    const dot: f32 = 2; // small enough to sit in the gap between lines
    const w = tagWidth(s);
    const h = 5 * dot + 8;
    const left = @round(x);
    const top = @round(y - h);
    fillRect(left, top, left + w, top + h, c, alpha);
    var i: f32 = 0;
    for (s) |ch| {
        const bits = pixBits(ch) orelse continue;
        for (0..5) |row| for (0..3) |col| {
            const bit: u4 = @intCast((4 - row) * 3 + (2 - col));
            if (bits & (@as(u16, 1) << bit) != 0) {
                const px = left + 4 + (i * 4 + f(col)) * dot;
                const py = top + 4 + f(row) * dot;
                fillRect(px, py, px + dot, py + dot, th.bg, alpha);
            }
        };
        i += 1;
    }
}
fn tagWidth(s: []const u8) f32 {
    var n: f32 = 0;
    for (s) |ch| if (pixBits(ch) != null) {
        n += 1;
    };
    return n * 8 - 2 + 8;
}

const Lock = struct { x0: f32, y0: f32, x1: f32, y1: f32, t: f32, kind: u8, label: [20]u8, ll: usize };
var locks: [48]Lock = undefined;
var nlocks: usize = 0;

fn lockOn(x0: f32, y0: f32, x1: f32, y1: f32, kind: u8, label: []const u8) void {
    if (nlocks >= locks.len) {
        for (1..nlocks) |i| locks[i - 1] = locks[i];
        nlocks -= 1;
    }
    // only the newest lock wears a tag; the ones before it drop theirs and let go sooner
    if (kind != 2) for (locks[0..nlocks]) |*o| if (o.kind != 2) {
        o.ll = 0;
        if (o.t >= 0.7) o.t = @max(o.t, 1.5);
    };
    var l: Lock = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .t = 0, .kind = kind, .label = undefined, .ll = @min(label.len, 20) };
    for (0..l.ll) |i| l.label[i] = label[i];
    locks[nlocks] = l;
    nlocks += 1;
}

fn drawLock(l: Lock) void {
    const k = clampf(l.t / 0.7, 0, 1);
    const locking = k < 1;
    const mx = (l.x0 + l.x1) / 2;
    const my = (l.y0 + l.y1) / 2 - scroll;
    var hw = (l.x1 - l.x0) / 2;
    var hh = (l.y1 - l.y0) / 2;
    var alpha: f32 = 1;
    var col = th.lock;
    var hatch = locking;
    if (l.kind == 2) {
        // target lost: the box collapses on what was deleted, hatched
        const s = 1 - 0.85 * k * k;
        hw *= s;
        hh *= s;
        alpha = 1 - k;
        hatch = true;
    } else {
        // lock on: it snaps in from wide to tight, red and hatched, then settles and lets go
        const grow: f32 = if (locking) 1 + 0.8 * (1 - k) * (1 - k) else 1;
        hw *= grow;
        hh *= grow;
        if (!locking) {
            col = th.box;
            alpha = 0.6 * (1 - clampf((l.t - 1.5) / 0.5, 0, 1));
        }
    }
    if (alpha <= 0.01) return;
    brackets(mx - hw, my - hh, mx + hw, my + hh, col, alpha, hatch);
    if (l.ll > 0) tag(mx - hw, my - hh - 2, l.label[0..l.ll], col, alpha);
}

fn fmtU(buf: []u8, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var k: usize = 0;
    var x = v;
    while (true) {
        tmp[k] = @intCast('0' + x % 10);
        k += 1;
        x /= 10;
        if (x == 0) break;
    }
    for (0..k) |i| buf[i] = tmp[k - 1 - i];
    return k;
}
fn fmtXY(buf: []u8, x: u32, y: u32) usize {
    buf[0] = 'X';
    buf[1] = ':';
    var n: usize = 2 + fmtU(buf[2..], x);
    buf[n] = ' ';
    buf[n + 1] = 'Y';
    buf[n + 2] = ':';
    n += 3;
    return n + fmtU(buf[n..], y);
}

// ───────────────────────────── layout ─────────────────────────────

fn relayout() void {
    nrows = 0;
    var i: usize = 0;
    var ln: u32 = 0;
    while (true) {
        var e = i;
        while (e < tlen and text[e] != '\n') e += 1;
        var s = i;
        var first = true;
        while (nrows < MAXR) {
            var w: f32 = 0;
            var k = s;
            var lastSp: usize = 0;
            while (k < e) : (k += 1) {
                const a = adv(text[k]);
                if (w + a > avail and k > s and text[k] != ' ') break;
                w += a;
                if (text[k] == ' ') lastSp = k + 1;
            }
            if (k >= e) {
                pushRow(s, e - s, ln, first);
                break;
            }
            const brk = if (lastSp > s) lastSp else k;
            pushRow(s, brk - s, ln, first);
            first = false;
            s = brk;
        }
        if (e >= tlen) break;
        i = e + 1;
        ln += 1;
    }
    if (nrows == 0) pushRow(0, 0, 0, true);
}
fn pushRow(s: usize, l: usize, ln: u32, first: bool) void {
    rowStart[nrows] = @intCast(s);
    rowLen[nrows] = @intCast(l);
    rowLine[nrows] = ln;
    rowFirst[nrows] = first;
    nrows += 1;
}
fn rowOf(c: usize) usize {
    var lo: usize = 0;
    var hi: usize = nrows;
    while (hi - lo > 1) {
        const mid = (lo + hi) / 2;
        if (rowStart[mid] <= c) lo = mid else hi = mid;
    }
    return lo;
}
fn rowTop(r: usize) f32 {
    return TOP + f(r) * LH;
}
fn xAt(r: usize, c: usize) f32 {
    var x = textX;
    var i: usize = rowStart[r];
    while (i < c) : (i += 1) x += adv(text[i]);
    return x;
}
fn rowEnd(r: usize) usize {
    const e = rowStart[r] + rowLen[r];
    if (r + 1 < nrows and !rowFirst[r + 1] and e > rowStart[r]) return e - 1;
    return e;
}
fn nearestIn(r: usize, px: f32) usize {
    var x = textX;
    var i: usize = rowStart[r];
    const e = rowEnd(r);
    while (i < e) : (i += 1) {
        const a = adv(text[i]);
        if (px < x + a / 2) break;
        x += a;
    }
    return i;
}
fn indexAt(x: f32, y: f32) usize {
    const r: usize = @intFromFloat(clampf(@floor((y + scroll - TOP) / LH), 0, f(nrows - 1)));
    return nearestIn(r, x);
}
fn lineStart(c: usize) usize {
    var i = c;
    while (i > 0 and text[i - 1] != '\n') i -= 1;
    return i;
}
fn lineEnd(c: usize) usize {
    var i = c;
    while (i < tlen and text[i] != '\n') i += 1;
    return i;
}

// ───────────────────────────── syntax ─────────────────────────────

const KW = [_][]const u8{ "const", "var", "fn", "pub", "return", "if", "else", "while", "for", "switch", "struct", "enum", "union", "try", "catch", "defer", "errdefer", "comptime", "break", "continue", "and", "or", "orelse", "unreachable", "undefined", "null", "true", "false", "export", "extern", "inline", "test", "error", "opaque", "packed", "align", "noalias", "threadlocal", "usingnamespace", "asm", "volatile", "callconv", "linksection", "nosuspend", "suspend", "resume", "await", "async", "anyframe" };
const TY = [_][]const u8{ "u8", "u16", "u32", "u64", "u128", "usize", "i8", "i16", "i32", "i64", "i128", "isize", "f16", "f32", "f64", "f80", "f128", "bool", "void", "type", "anytype", "anyerror", "noreturn", "comptime_int", "comptime_float", "c_int", "c_uint", "c_char" };

var cls: [1 << 16]u8 = undefined;
// 0 plain · 1 keyword · 2 builtin/type · 3 string · 4 number · 5 comment · 6 punctuation
fn classify(s: usize, e: usize) void {
    const n = @min(e - s, cls.len);
    var i: usize = 0;
    while (i < n) {
        const c = text[s + i];
        if (c == '/' and i + 1 < n and text[s + i + 1] == '/') {
            while (i < n) : (i += 1) cls[i] = 5;
        } else if (c == '\\' and i + 1 < n and text[s + i + 1] == '\\') {
            while (i < n) : (i += 1) cls[i] = 3;
        } else if (c == '"' or c == '\'') {
            cls[i] = 3;
            i += 1;
            while (i < n) {
                cls[i] = 3;
                if (text[s + i] == '\\') {
                    if (i + 1 < n) cls[i + 1] = 3;
                    i += 2;
                    continue;
                }
                i += 1;
                if (text[s + i - 1] == c) break;
            }
        } else if (c == '@') {
            cls[i] = 2;
            i += 1;
            while (i < n and isWord(text[s + i])) : (i += 1) cls[i] = 2;
        } else if (c >= '0' and c <= '9') {
            while (i < n and (isWord(text[s + i]) or text[s + i] == '.')) : (i += 1) cls[i] = 4;
        } else if (isWord(c)) {
            var j = i;
            while (j < n and isWord(text[s + j])) j += 1;
            const w = text[s + i .. s + j];
            var k: u8 = 0;
            for (KW) |kw| if (eql(w, kw)) {
                k = 1;
                break;
            };
            if (k == 0) for (TY) |ty| if (eql(w, ty)) {
                k = 2;
                break;
            };
            while (i < j) : (i += 1) cls[i] = k;
        } else {
            cls[i] = switch (c) {
                '(', ')', '{', '}', '[', ']', ';', ',', '.', '=', '+', '-', '*', '/', '<', '>', '!', '&', '|', '^', '%', '~', ':', '?' => 6,
                else => 0,
            };
            i += 1;
        }
    }
}
// which highlight each class wears: keyword lavender, builtin/type sky, string mint, number rose
fn hlOf(k: u8) ?usize {
    return switch (k) {
        1 => 3,
        2 => 1,
        3 => 0,
        4 => 2,
        else => null,
    };
}
const Ink = struct { c: Col, a: f32 };
fn inkOf(k: u8) Ink {
    if (dark) {
        if (hlOf(k)) |h| return .{ .c = th.hl[h], .a = 1 };
    }
    return switch (k) {
        5 => .{ .c = th.ink, .a = 0.42 },
        6 => .{ .c = th.ink, .a = 0.62 },
        else => .{ .c = th.ink, .a = 1 },
    };
}

// ───────────────────────────── springing letters ─────────────────────────────

const Pop = struct { idx: usize, t: f32, hl: u8 };
fn popAge(idx: usize) ?f32 {
    for (pops[0..npops]) |p| if (p.idx == idx) return p.t;
    return null;
}

const SWEEP_T: f32 = 0.32;
const Sweep = struct { start: usize, t: f32 };
var sweeps: [64]Sweep = undefined;
var nsweeps: usize = 0;
fn sweepAge(start: usize) ?f32 {
    for (sweeps[0..nsweeps]) |w| if (w.start == start) return w.t;
    return null;
}
fn easeOut(x: f32) f32 {
    const u = 1 - clampf(x, 0, 1);
    return 1 - u * u * u;
}
// the letter at `i` just changed: if it now belongs to a highlighted token, sweep that token in
fn noteToken(i: usize) void {
    if (i >= tlen) return;
    const ls = lineStart(i);
    classify(ls, lineEnd(i));
    const ci = i - ls;
    if (ci >= cls.len) return;
    const k = cls[ci];
    if (hlOf(k) == null) return;
    var a = ci;
    while (a > 0 and cls[a - 1] == k) a -= 1;
    const start = ls + a;
    if (sweepAge(start) != null) return;
    if (nsweeps >= sweeps.len) {
        for (1..nsweeps) |j| sweeps[j - 1] = sweeps[j];
        nsweeps -= 1;
    }
    sweeps[nsweeps] = .{ .start = start, .t = 0 };
    nsweeps += 1;
}
const Run = struct { k0: usize, k1: usize, x0: f32, x1: f32, kind: u8, reveal: f32 };
var pops: [96]Pop = undefined;
var npops: usize = 0;

var combo: u32 = 0;
var lastTypeAt: f32 = -10;
var hlIdx: u8 = 0;

// a finished word gets locked on to
fn lockWord(endIdx: usize) void {
    if (endIdx == 0) return;
    var a = endIdx;
    while (a > 0 and isWord(text[a - 1])) a -= 1;
    if (a == endIdx) return;
    const r = rowOf(a);
    if (rowOf(endIdx - 1) != r) return;
    var buf: [20]u8 = undefined;
    const n = fmtXY(&buf, @intCast(a - lineStart(a) + 1), rowLine[r] + 1);
    lockOn(xAt(r, a) - 8, rowTop(r) + 8, xAt(r, endIdx) + 8, rowTop(r) + LH - 6, 0, buf[0..n]);
}

// deleted text dissolves: its cells fill with dense glyphs in rose that fade down the ramp
fn dissolve(a: usize, b: usize) void {
    if (b <= a or nrows == 0) return;
    var r = rowOf(a);
    var bx0: f32 = 1e9;
    var by0: f32 = 1e9;
    var bx1: f32 = -1e9;
    var by1: f32 = -1e9;
    var budget: usize = 40;
    while (r < nrows and rowStart[r] < b) : (r += 1) {
        const top = rowTop(r) - scroll;
        if (top > f(H) + LH) break;
        const s0 = @max(a, rowStart[r]);
        const s1 = @min(b, rowStart[r] + rowLen[r]);
        if (top < -LH or s1 <= s0) continue;
        var x = xAt(r, s0);
        bx0 = @min(bx0, x);
        by0 = @min(by0, rowTop(r) + 8);
        var i = s0;
        while (i < s1) : (i += 1) {
            const c = text[i];
            const w = adv(c);
            if (c != ' ') {
                blob(x + w / 2, top + MID, 18, 1, 2);
                if (budget > 0) {
                    // a fish or two slips out of every letter and sinks away
                    if (nfish < fish.len) {
                        fish[nfish] = .{ .x = x + w / 2, .y = top + MID, .vx = rnd(-160, 160), .vy = rnd(60, 260), .turn = rnd(-4, 4), .t = 0, .life = rnd(0.3, 0.6), .hue = if (rand() < 0.7) 2 else 3 };
                        nfish += 1;
                    }
                    budget -= 1;
                }
            }
            x += w;
        }
        bx1 = @max(bx1, x);
        by1 = @max(by1, rowTop(r) + LH - 6);
    }
    if (bx1 > bx0) lockOn(bx0 - 8, by0, bx1 + 8, by1, 2, "");
}

// ───────────────────────────── the caret ─────────────────────────────

const BW: f32 = 4;
const BH: f32 = 68;
const BOFF: f32 = 14;
const OFF = [4][2]f32{ .{ 0, 0 }, .{ BW, 0 }, .{ BW, BH }, .{ 0, BH } };
var corner: [4][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
var rate: [4]f32 = .{ 40, 40, 40, 40 }; // each corner's spring frequency, ω
var cvel: [4][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
var tgx: f32 = 0;
var tgy: f32 = 0;
var press: f32 = 0;
var pressV: f32 = 0;
var pressGoal: f32 = 0;
var recoil: f32 = 0; // the caret's sideways spring
var recoilV: f32 = 0;
var shX: f32 = 0; // the page's nudge, applied by the host as a css transform
var shY: f32 = 0;
var shVX: f32 = 0;
var shVY: f32 = 0;
fn nudge(x: f32, y: f32) void {
    shVX += x;
    shVY += y;
}

// a jolt that runs back along the line from the letter just typed
const Wave = struct { row: usize, idx: usize, t: f32, amp: f32 };
var waves: [6]Wave = undefined;
var nwaves: usize = 0;
fn jostle(idx: usize, amp: f32) void {
    if (nwaves >= waves.len) {
        for (1..nwaves) |i| waves[i - 1] = waves[i];
        nwaves -= 1;
    }
    waves[nwaves] = .{ .row = rowOf(idx), .idx = idx, .t = 0, .amp = amp };
    nwaves += 1;
}
fn waveDy(r: usize, i: usize) f32 {
    var dy: f32 = 0;
    for (waves[0..nwaves]) |w| {
        if (w.row != r) continue;
        const d = f(if (i > w.idx) i - w.idx else w.idx - i);
        if (d > 16) continue;
        const tt = w.t - d * 0.016;
        if (tt <= 0) continue;
        dy -= w.amp * @exp(-d * 0.2) * @exp(-tt * 11) * @sin(tt * 36);
    }
    return dy;
}

fn caretXY(c: usize) [2]f32 {
    const r = rowOf(c);
    return .{ xAt(r, c) - BW / 2, rowTop(r) + BOFF };
}

fn cursorMoved(quiet: bool, snap: bool) void {
    const p = caretXY(cur);
    const dx = p[0] - tgx;
    const dy = p[1] - tgy;
    const d = @sqrt(dx * dx + dy * dy);
    if (!quiet and !snap and (@abs(dy) > LH * 1.5 or @abs(dx) > 260)) {
        // a jump: an ASCII streak along the way, a splash and a lock-on where it lands
        if (nstreak < streaks.len) {
            streaks[nstreak] = .{ .ax = tgx + BW / 2, .ay = tgy + BH / 2 - scroll, .bx = p[0] + BW / 2, .by = p[1] + BH / 2 - scroll, .t = 0, .hue = hlIdx };
            nstreak += 1;
        }
        splash(p[0] + BW / 2, p[1] + BH / 2 - scroll, 1.0, 4, hlIdx);
        nudge(clampf(dx * 0.6, -260, 260), clampf(dy * 0.6, -260, 260));
        const r = rowOf(cur);
        var buf: [20]u8 = undefined;
        const n = fmtXY(&buf, @intCast(cur - lineStart(cur) + 1), rowLine[r] + 1);
        lockOn(p[0] - 22, p[1] - 10, p[0] + BW + 22, p[1] + BH + 10, 1, buf[0..n]);
    }
    tgx = p[0];
    tgy = p[1];
    if (snap) {
        for (0..4) |i| {
            corner[i] = .{ tgx + OFF[i][0], tgy + OFF[i][1] };
            cvel[i] = .{ 0, 0 };
        }
    } else {
        const short = @abs(dy) < 1 and @abs(dx) < 70;
        const ux = if (d > 0) dx / d else 0;
        const uy = if (d > 0) dy / d else 0;
        for (0..4) |i| {
            const ox = OFF[i][0] - BW / 2;
            const oy = OFF[i][1] - BH / 2;
            const dot = (ox * ux + oy * uy) / @sqrt(ox * ox + oy * oy);
            // the leading edge springs ahead, the trailing edge follows; a long move smears
            rate[i] = if (short) 52 else if (dot > 0.15) 58 else if (dot < -0.15) 21 else 32;
        }
    }
    ensureVisible();
}

fn ensureVisible() void {
    const top = rowTop(rowOf(cur));
    if (top - scrollGoal < TOP) scrollGoal = top - TOP;
    if (top + LH - scrollGoal > f(H) - 180) scrollGoal = top + LH - (f(H) - 180);
    scrollGoal = clampf(scrollGoal, 0, maxScroll());
}
fn maxScroll() f32 {
    return @max(0, TOP + f(nrows) * LH - f(H) * 0.45);
}
fn settled() bool {
    for (0..4) |i| {
        if (@abs(corner[i][0] - (tgx + OFF[i][0])) > 0.3 or @abs(corner[i][1] - (tgy + OFF[i][1])) > 0.3) return false;
        if (@abs(cvel[i][0]) > 3 or @abs(cvel[i][1]) > 3) return false;
    }
    return true;
}

// ───────────────────────────── editing ─────────────────────────────

fn selMin() usize {
    return @min(cur, anchor);
}
fn selMax() usize {
    return @max(cur, anchor);
}
fn beginEdit(kind: u8) void {
    if (!(kind == lastKind and kind != 3 and clock - lastEditAt < 1.0 and cur == lastEditEnd)) group += 1;
    lastKind = kind;
    lastEditAt = clock;
}

// the one primitive every edit goes through: delete `del` bytes at `pos`, insert `ins`
fn replace(pos: usize, del: usize, ins: []const u8) void {
    const room = MAXT - (tlen - del);
    const insn = @min(ins.len, room);
    dissolve(pos, pos + del);

    if (recording) {
        if (nops >= ops.len or arenaLen + del + insn > arena.len) {
            nops = 0;
            opTop = 0;
            arenaLen = 0;
        }
        nops = opTop;
        ops[nops] = .{ .pos = @intCast(pos), .del_off = @intCast(arenaLen), .del_len = @intCast(del), .ins_off = @intCast(arenaLen + del), .ins_len = @intCast(insn), .before = @intCast(cur), .after = @intCast(pos + insn), .group = group };
        for (0..del) |i| arena[arenaLen + i] = text[pos + i];
        for (0..insn) |i| arena[arenaLen + del + i] = ins[i];
        arenaLen += del + insn;
        nops += 1;
        opTop = nops;
    }

    var nl = false;
    for (text[pos .. pos + del]) |c| if (c == '\n') {
        nl = true;
    };
    for (ins[0..insn]) |c| if (c == '\n') {
        nl = true;
    };
    const rowsBefore = nrows;
    const r0 = rowOf(pos);

    const tail = tlen - (pos + del);
    if (insn > del) {
        var i: usize = tail;
        while (i > 0) : (i -= 1) text[pos + insn + i - 1] = text[pos + del + i - 1];
    } else if (insn < del) {
        for (0..tail) |i| text[pos + insn + i] = text[pos + del + i];
    }
    for (0..insn) |i| text[pos + i] = ins[i];
    tlen = tlen - del + insn;
    relayout();

    // sweeps follow the tokens they belong to
    var q: usize = 0;
    while (q < nsweeps) {
        var w = &sweeps[q];
        if (w.start >= pos + del) {
            w.start = w.start + insn - del;
        } else if (w.start >= pos and del > 0) {
            sweeps[q] = sweeps[nsweeps - 1];
            nsweeps -= 1;
            continue;
        }
        q += 1;
    }
    // springing letters follow the text they belong to
    var k: usize = 0;
    while (k < npops) {
        var p = &pops[k];
        if (p.idx >= pos + del) {
            p.idx = p.idx + insn - del;
        } else if (p.idx >= pos) {
            pops[k] = pops[npops - 1];
            npops -= 1;
            continue;
        }
        k += 1;
    }

    if (nl or nrows != rowsBefore) full = true else {
        var a = r0;
        while (a > 0 and !rowFirst[a]) a -= 1;
        var b = r0 + 1;
        while (b < nrows and !rowFirst[b]) b += 1;
        pending.addf(0, rowTop(a) - scroll - 4, f(W), rowTop(b) - scroll + 4);
    }
    changedFlag = true;
    countWords();
}

fn deleteSel() bool {
    if (cur == anchor) return false;
    const a = selMin();
    replace(a, selMax() - a, &[_]u8{});
    cur = a;
    anchor = a;
    full = true;
    return true;
}

fn insertStr(s: []const u8, kind: u8) void {
    beginEdit(kind);
    if (cur != anchor) {
        const a = selMin();
        replace(a, selMax() - a, s);
        cur = a + s.len;
        full = true;
    } else {
        replace(cur, 0, s);
        cur += s.len;
    }
    cur = @min(cur, tlen);
    anchor = cur;
    lastEditEnd = cur;
}

fn countWords() void {
    var n: u32 = 0;
    var inw = false;
    for (text[0..tlen]) |c| {
        const w = c != ' ' and c != '\n' and c != '\t';
        if (w and !inw) n += 1;
        inw = w;
    }
    wordCount = n;
}
fn wordLeft(c: usize) usize {
    var i = c;
    while (i > 0 and !isWord(text[i - 1])) i -= 1;
    while (i > 0 and isWord(text[i - 1])) i -= 1;
    return i;
}
fn wordRight(c: usize) usize {
    var i = c;
    while (i < tlen and !isWord(text[i])) i += 1;
    while (i < tlen and isWord(text[i])) i += 1;
    return i;
}
fn moveTo(c: usize, shift: bool, keepGoal: bool) void {
    const hadSel = cur != anchor;
    cur = @min(c, tlen);
    if (!shift) anchor = cur;
    if (!keepGoal) goalX = -1;
    if (hadSel or cur != anchor) full = true;
    cursorMoved(shift, false);
}
fn vertical(rows: i32, shift: bool) void {
    const r = rowOf(cur);
    if (goalX < 0) goalX = xAt(r, cur);
    const nr: i32 = @as(i32, @intCast(r)) + rows;
    if (nr < 0) return moveTo(0, shift, true);
    if (nr >= @as(i32, @intCast(nrows))) return moveTo(tlen, shift, true);
    moveTo(nearestIn(@intCast(nr), goalX), shift, true);
}

// ───────────────────────────── rendering ─────────────────────────────

var lineBase: usize = 0;

fn render(rect: Rect) void {
    cx0 = @max(rect.x0, 0);
    cy0 = @max(rect.y0, 0);
    cx1 = @min(rect.x1, W);
    cy1 = @min(rect.y1, H);
    if (cx1 <= cx0 or cy1 <= cy0) return;

    // 1 · the page: flat
    const w: usize = @intCast(W);
    var y = cy0;
    while (y < cy1) : (y += 1) {
        var i = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(cx0))) * 4;
        const e = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(cx1))) * 4;
        while (i < e) : (i += 4) {
            fb[i] = @intCast(th.bg[0]);
            fb[i + 1] = @intCast(th.bg[1]);
            fb[i + 2] = @intCast(th.bg[2]);
            fb[i + 3] = 255;
        }
    }

    // 2 · the ASCII field, under the words so they always read
    drawField();

    const r0: usize = @intFromFloat(clampf(@floor((f(cy0) + scroll - TOP) / LH - 1), 0, f(nrows)));
    const r1: usize = @intFromFloat(clampf(@ceil((f(cy1) + scroll - TOP) / LH + 1), 0, f(nrows)));
    const curLine = rowLine[rowOf(cur)];

    // 3 · ff-tracking, under the words so it never hides them
    for (locks[0..nlocks]) |l| drawLock(l);
    const fr = fieldRect();

    // 4 · selection
    if (cur != anchor) {
        const a = selMin();
        const b = selMax();
        var r = r0;
        while (r < r1) : (r += 1) {
            const s0 = @max(a, rowStart[r]);
            const s1 = @min(b, rowStart[r] + rowLen[r]);
            const eol = b > rowStart[r] + rowLen[r];
            if (s1 < s0 or (s1 == s0 and !eol)) continue;
            const top = rowTop(r) - scroll;
            fillRect(xAt(r, s0), top + 6, xAt(r, s1) + (if (eol) @as(f32, 12) else 0), top + LH - 6, th.pop[3], if (dark) 0.32 else 0.22);
        }
    }

    // 4 · gutter, highlighter marks (on white), text
    var r = r0;
    var clsLine: u32 = 0xffffffff;
    while (r < r1) : (r += 1) {
        const top = rowTop(r) - scroll;
        if (rowFirst[r]) {
            var buf: [10]u8 = undefined;
            const n = fmtU(&buf, rowLine[r] + 1);
            var gw: f32 = 0;
            for (buf[0..n]) |c| gw += adv(c);
            var gx = textX - 40 - gw;
            const here = rowLine[r] == curLine;
            for (buf[0..n]) |c| {
                glyph(c, gx, top, if (here) th.pop[3] else th.ink, if (here) 0.95 else 0.22);
                gx += adv(c);
            }
        }
        if (rowLine[r] != clsLine) {
            var a = r;
            while (a > 0 and !rowFirst[a]) a -= 1;
            classify(rowStart[a], lineEnd(rowStart[a]));
            clsLine = rowLine[r];
            lineBase = rowStart[a];
        }
        const s = rowStart[r];
        const len = rowLen[r];
        // this row's runs of highlighted kinds, and how far each has swept in
        var runs: [64]Run = undefined;
        var nrun: usize = 0;
        {
            var k: usize = 0;
            var x = textX;
            while (k < len) {
                const ci = s + k - lineBase;
                const kind: u8 = if (ci < cls.len) cls[ci] else 0;
                if (hlOf(kind) != null and nrun < runs.len) {
                    const k0 = k;
                    const x0 = x;
                    while (k < len and (s + k - lineBase) < cls.len and cls[s + k - lineBase] == kind) : (k += 1) x += adv(text[s + k]);
                    var x1 = x;
                    // the newest letter's share of the mark eases out to meet it
                    if (popAge(s + k - 1)) |t| x1 -= adv(text[s + k - 1]) * (1 - easeOut(t / 0.16));
                    // a token can begin on an earlier wrapped row: find where it really starts
                    var a0 = s + k0 - lineBase;
                    while (a0 > 0 and cls[a0 - 1] == kind) a0 -= 1;
                    const reveal = if (sweepAge(lineBase + a0)) |t| easeOut(t / SWEEP_T) else 1;
                    runs[nrun] = .{ .k0 = k0, .k1 = k, .x0 = x0, .x1 = x1, .kind = kind, .reveal = reveal };
                    nrun += 1;
                } else {
                    x += adv(text[s + k]);
                    k += 1;
                }
            }
        }
        if (!dark) {
            // on white the pastels are a highlighter, laid down left to right like a marker
            for (runs[0..nrun]) |rn| {
                const h = hlOf(rn.kind).?;
                const xe = rn.x0 + (rn.x1 - rn.x0) * rn.reveal;
                if (xe - rn.x0 < 0.5) continue;
                roundRect(rn.x0 - 5, top + BASE - 34, xe + 5, top + BASE + 13, 11, th.hl[h], 0.95);
                // while it sweeps, the marker's tip is a touch deeper
                if (rn.reveal < 1) roundRect(@max(rn.x0 - 5, xe - 12), top + BASE - 34, xe + 5, top + BASE + 13, 11, th.pop[h], 0.28 * (1 - rn.reveal));
            }
        }
        var x = textX;
        var ri: usize = 0;
        for (0..len) |k| {
            const idx = s + k;
            const c = text[idx];
            const ci = idx - lineBase;
            const kind: u8 = if (ci < cls.len) cls[ci] else 0;
            const ink = inkOf(kind);
            var col = ink.c;
            // on black the colour itself washes across a token as it's recognised
            while (ri < nrun and runs[ri].k1 <= k) ri += 1;
            if (dark and ri < nrun and runs[ri].k0 <= k and runs[ri].reveal < 1) {
                const rn = runs[ri];
                const sweepX = rn.x0 + (rn.x1 - rn.x0 + 24) * rn.reveal;
                col = mix(th.ink, ink.c, (sweepX - (x + adv(c) / 2)) / 24);
            }
            const dy = if (nwaves > 0) waveDy(r, idx) else 0;
            // where the field is live, a ring of page colour keeps every letter legible
            if (!fr.empty() and c != ' ' and x + 40 > f(fr.x0) and x - 10 < f(fr.x1) and top + LH > f(fr.y0) and top < f(fr.y1)) halo(c, x, top + dy);
            var popped = false;
            for (pops[0..npops]) |p| if (p.idx == idx) {
                // the stamp: a quick drop, stretched; then it lands, squashes and wobbles back
                const FALL: f32 = 0.05;
                var sx: f32 = 1;
                var sy: f32 = 1;
                var py: f32 = 0;
                if (p.t < FALL) {
                    const kf = p.t / FALL;
                    py = -16 * (1 - kf) * (1 - kf);
                    sx = 0.88;
                    sy = 1.14;
                } else {
                    const u = p.t - FALL;
                    const e = @exp(-12 * u) * @cos(30 * u);
                    sy = 1 - 0.24 * e;
                    sx = 1 + 0.18 * e;
                }
                glyphStamp(c, x, top, sx, sy, py + dy, mix(th.pop[p.hl], col, p.t / 0.35), ink.a);
                popped = true;
                break;
            };
            // a jostled letter is drawn between pixels, so the ripple glides instead of stepping
            if (!popped) {
                if (@abs(dy) > 0.04) glyphStamp(c, x, top, 1, 1, dy, col, ink.a) else glyph(c, x, top, col, ink.a);
            }
            x += adv(c);
        }
    }

    // 6 · the caret: a bar in the current highlight; it squashes while a key is held
    var q: [4][2]f32 = undefined;
    for (0..4) |i| q[i] = .{ corner[i][0] + recoil, corner[i][1] - scroll };
    const sq = press * 9;
    q[0][1] += sq;
    q[1][1] += sq;
    q[0][0] -= press * 3;
    q[3][0] -= press * 3;
    q[1][0] += press * 3;
    q[2][0] += press * 3;
    poly(&q, th.pop[hlIdx], if (focused) (if (cur == anchor) @as(f32, 1) else 0.6) else 0.3);
}

fn cursorRect() Rect {
    var r: Rect = .{};
    for (corner) |c| r.addf(c[0] - 18, c[1] - scroll - 14, c[0] + 18, c[1] - scroll + 14);
    return r;
}

fn fxRect() Rect {
    var r: Rect = .{};
    for (locks[0..nlocks]) |l| {
        const gx = (l.x1 - l.x0) * 0.45 + 6;
        const gy = (l.y1 - l.y0) * 0.45 + 6;
        r.addf(l.x0 - gx, l.y0 - scroll - gy - 40, @max(l.x1 + gx, l.x0 + tagWidth(l.label[0..l.ll]) + 20), l.y1 - scroll + gy);
    }
    for (pops[0..npops]) |p| {
        if (p.idx >= tlen) continue;
        const row = rowOf(p.idx);
        const x = xAt(row, p.idx);
        r.addf(x - 40, rowTop(row) - scroll - 12, x + 60, rowTop(row) - scroll + LH + 12);
    }
    for (sweeps[0..nsweeps]) |w| {
        if (w.start >= tlen) continue;
        const row = rowOf(w.start);
        r.addf(0, rowTop(row) - scroll - 4, f(W), rowTop(row) - scroll + LH * 2 + 4);
    }
    for (waves[0..nwaves]) |wv| {
        if (wv.row >= nrows) continue;
        r.addf(0, rowTop(wv.row) - scroll - 24, f(W), rowTop(wv.row) - scroll + LH + 24);
    }
    r.merge(fieldRect());
    r.merge(cursorRect());
    return r;
}

// ───────────────────────────── exports ─────────────────────────────

export fn fbPtr() [*]u8 {
    return &fb;
}
export fn scratchPtr() [*]u8 {
    return &scratch;
}
export fn scratchCap() u32 {
    return MAXT;
}
export fn textPtr() [*]u8 {
    return &text;
}
export fn textLen() u32 {
    return @intCast(tlen);
}
export fn maxW() u32 {
    return MAXW;
}
export fn maxH() u32 {
    return MAXH;
}
export fn words() u32 {
    return wordCount;
}
export fn changed() u32 {
    const c = changedFlag;
    changedFlag = false;
    return @intFromBool(c);
}
export fn outX() i32 {
    return out.x0;
}
export fn outY() i32 {
    return out.y0;
}
export fn outW() i32 {
    return out.x1 - out.x0;
}
export fn outH() i32 {
    return out.y1 - out.y0;
}

export fn keyDown() void {
    pressGoal = 1;
}
export fn keyUp() void {
    pressGoal = 0;
}
export fn shakeX() f32 {
    return shX;
}
export fn shakeY() f32 {
    return shY;
}

export fn setTheme(d: u32) void {
    dark = d != 0;
    th = if (dark) &DARK else &LIGHT;
    full = true;
}

export fn resize(w: u32, h: u32) void {
    W = @intCast(@min(w, MAXW));
    H = @intCast(@min(h, MAXH));
    fw = @intCast(@divFloor(W + CWc - 1, CWc));
    fh = @intCast(@divFloor(H + CHc - 1, CHc));
    @memset(fieldI[0..], 0);
    ax0 = 0;
    ax1 = 0;
    ay0 = 0;
    ay1 = 0;
    nrip = 0;
    nfish = 0;
    nstreak = 0;
    textX = @max(200, @floor(f(W) * 0.1));
    avail = @max(300, f(W) - textX - 160);
    relayout();
    cur = @min(cur, tlen);
    anchor = @min(anchor, tlen);
    cursorMoved(true, true);
    scroll = scrollGoal;
    nlocks = 0;
    npops = 0;
    nsweeps = 0;
    full = true;
}

export fn loadText(n: u32) void {
    const len = @min(n, MAXT);
    for (0..len) |i| text[i] = scratch[i];
    tlen = len;
    cur = 0;
    anchor = 0;
    nops = 0;
    opTop = 0;
    arenaLen = 0;
    relayout();
    countWords();
    cursorMoved(true, true);
    full = true;
}
export fn setCursor(c: u32) void {
    cur = @min(c, tlen);
    anchor = cur;
    cursorMoved(true, true);
    scroll = scrollGoal;
    full = true;
}
export fn cursorPos() u32 {
    return @intCast(cur);
}
export fn focus(on: u32) void {
    focused = on != 0;
    pending.merge(cursorRect());
}

export fn typeChar(code: u32) void {
    const c: u8 = if (code >= 32 and code < 127) @intCast(code) else '?';
    const wordEnded = !isWord(c) and cur > 0 and cur == anchor and isWord(text[cur - 1]);
    const endIdx = cur;
    insertStr(&[_]u8{c}, 1);
    if (wordEnded) lockWord(endIdx);

    combo = if (clock - lastTypeAt < 0.26) combo + 1 else 1;
    lastTypeAt = clock;
    if (c == ' ') hlIdx = (hlIdx + 1) % 4; // each word gets the next highlight
    if (c != ' ' and npops < pops.len) {
        pops[npops] = .{ .idx = cur - 1, .t = 0, .hl = hlIdx };
        noteToken(cur - 1);
        npops += 1;
    }
    const at = caretXY(cur);
    const power = 0.65 + @min(f(combo), 16) * 0.035;
    if (c == ' ') splash(at[0], at[1] + BH * 0.6 - scroll, 0.4, 0, hlIdx) else splash(at[0] - adv(c) / 2, at[1] + BH * 0.6 - scroll, power, 1 + @min(combo, 16) / 6, hlIdx);
    pressV += 5;
    recoilV += 240;
    jostle(cur - 1, if (c == ' ') 2.5 else 4 + @min(f(combo), 12) * 0.15);
    nudge(rnd(-30, 30), 70);
    cursorMoved(true, false);
}

export fn insertText(n: u32) void {
    const len = @min(n, MAXT);
    insertStr(scratch[0..len], 3);
    full = true;
    cursorMoved(false, false);
}
export fn selText() u32 {
    if (cur == anchor) return 0;
    const a = selMin();
    const b = selMax();
    for (a..b) |i| scratch[i - a] = text[i];
    return @intCast(b - a);
}
export fn cutSel() void {
    beginEdit(3);
    _ = deleteSel();
    cursorMoved(true, false);
}

// keys: 1 ← 2 → 3 ↑ 4 ↓ 5 home 6 end 7 backspace 8 delete 9 enter 10 tab
//       11 select all 12 undo 13 redo 14 page up 15 page down · mods: 1 shift 2 alt 4 cmd/ctrl
export fn key(k: u32, mods: u32) void {
    const shift = mods & 1 != 0;
    const alt = mods & 2 != 0;
    const meta = mods & 4 != 0;
    switch (k) {
        1 => {
            if (cur != anchor and !shift) return moveTo(selMin(), false, false);
            const r = rowOf(cur);
            moveTo(if (meta) rowStart[r] else if (alt) wordLeft(cur) else if (cur > 0) cur - 1 else 0, shift, false);
        },
        2 => {
            if (cur != anchor and !shift) return moveTo(selMax(), false, false);
            const r = rowOf(cur);
            moveTo(if (meta) rowEnd(r) else if (alt) wordRight(cur) else @min(cur + 1, tlen), shift, false);
        },
        3 => if (meta) moveTo(0, shift, false) else vertical(-1, shift),
        4 => if (meta) moveTo(tlen, shift, false) else vertical(1, shift),
        5 => moveTo(rowStart[rowOf(cur)], shift, false),
        6 => moveTo(rowEnd(rowOf(cur)), shift, false),
        14 => vertical(-@as(i32, @intFromFloat(f(H) / LH * 0.7)), shift),
        15 => vertical(@as(i32, @intFromFloat(f(H) / LH * 0.7)), shift),
        7, 8 => {
            beginEdit(2);
            if (!deleteSel()) {
                var a = cur;
                var b = cur;
                if (k == 7) {
                    a = if (meta) lineStart(cur) else if (alt) wordLeft(cur) else if (cur > 0) cur - 1 else 0;
                    if (!meta and !alt and cur > 0 and text[cur - 1] == ' ') {
                        const ls = lineStart(cur);
                        var allSp = true;
                        for (text[ls..cur]) |c| if (c != ' ') {
                            allSp = false;
                        };
                        if (allSp and cur - ls > 0) a = cur - ((cur - ls - 1) % 4 + 1);
                    }
                } else {
                    b = if (meta) lineEnd(cur) else if (alt) wordRight(cur) else @min(cur + 1, tlen);
                }
                if (b > a) {
                    replace(a, b - a, &[_]u8{});
                    cur = a;
                    anchor = a;
                }
            }
            lastEditEnd = cur;
            combo = 0;
            recoilV -= 200;
            if (cur > 0) jostle(cur - 1, 5);
            nudge(if (rand() < 0.5) @as(f32, -110) else 110, 20);
            cursorMoved(true, false);
        },
        9 => {
            const ls = lineStart(cur);
            var n: usize = 0;
            while (ls + n < cur and text[ls + n] == ' ') n += 1;
            var j = cur;
            while (j > ls and text[j - 1] == ' ') j -= 1;
            if (j > ls and (text[j - 1] == '{' or text[j - 1] == '(' or text[j - 1] == '[')) n += 4;
            if (cur == anchor and cur > 0 and isWord(text[cur - 1])) lockWord(cur);
            var buf: [129]u8 = undefined;
            buf[0] = '\n';
            const m = @min(n, 128);
            for (0..m) |i| buf[1 + i] = ' ';
            const from = caretXY(cur);
            insertStr(buf[0 .. 1 + m], 3);
            full = true;
            hlIdx = (hlIdx + 1) % 4;
            cursorMoved(true, false);
            const to = caretXY(cur);
            if (nstreak < streaks.len) {
                streaks[nstreak] = .{ .ax = from[0], .ay = from[1] + BH / 2 - scroll, .bx = to[0], .by = to[1] + BH / 2 - scroll, .t = 0, .hue = hlIdx };
                nstreak += 1;
            }
            splash(to[0], to[1] + BH / 2 - scroll, 1.0, 3, hlIdx);
            nudge(0, 260);
        },
        10 => {
            const col = cur - lineStart(cur);
            insertStr("    "[0 .. 4 - col % 4], 3);
            cursorMoved(true, false);
        },
        11 => {
            anchor = 0;
            cur = tlen;
            full = true;
            cursorMoved(true, false);
        },
        12, 13 => {
            recording = false;
            defer recording = true;
            if (k == 12 and opTop > 0) {
                const g = ops[opTop - 1].group;
                while (opTop > 0 and ops[opTop - 1].group == g) {
                    opTop -= 1;
                    const o = ops[opTop];
                    replace(o.pos, o.ins_len, arena[o.del_off .. o.del_off + o.del_len]);
                    cur = o.before;
                }
            } else if (k == 13 and opTop < nops) {
                const g = ops[opTop].group;
                while (opTop < nops and ops[opTop].group == g) {
                    const o = ops[opTop];
                    replace(o.pos, o.del_len, arena[o.ins_off .. o.ins_off + o.ins_len]);
                    cur = o.after;
                    opTop += 1;
                }
            }
            cur = @min(cur, tlen);
            anchor = cur;
            lastKind = 0;
            full = true;
            cursorMoved(false, false);
        },
        else => {},
    }
}

// pointer: 0 down · 1 drag · 2 up · 3 double click (select word)
export fn pointer(kind: u32, x: f32, y: f32, mods: u32) void {
    const c = indexAt(x, y);
    switch (kind) {
        0 => {
            dragging = true;
            cur = c;
            if (mods & 1 == 0) anchor = c;
            goalX = -1;
            full = true;
            cursorMoved(false, false);
        },
        1 => if (dragging and c != cur) {
            cur = c;
            full = true;
            cursorMoved(true, false);
        },
        2 => dragging = false,
        3 => {
            anchor = wordLeft(@min(c + 1, tlen));
            if (anchor > c) anchor = c;
            cur = wordRight(c);
            full = true;
            cursorMoved(true, false);
            if (cur > anchor) {
                const r = rowOf(anchor);
                var buf: [20]u8 = undefined;
                const n = fmtXY(&buf, @intCast(anchor - lineStart(anchor) + 1), rowLine[r] + 1);
                lockOn(xAt(r, anchor) - 8, rowTop(r) + 8, xAt(r, cur) + 8, rowTop(r) + LH - 6, 0, buf[0..n]);
            }
        },
        else => {},
    }
}

export fn wheel(dy: f32) void {
    scrollGoal = clampf(scrollGoal + dy, 0, maxScroll());
}

// one frame: step everything, redraw what changed. Bit 0: pixels changed. Bit 1: still moving.
export fn frame(dtms: f32) u32 {
    const dt = clampf(dtms / 1000, 0, 0.05);
    clock += dt;

    const ds = scrollGoal - scroll;
    if (@abs(ds) > 0.4) {
        scroll += ds * (1 - @exp(-dt * 14));
        full = true;
    } else if (ds != 0) {
        scroll = scrollGoal;
        full = true;
    }

    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(dt / (1.0 / 240.0)))));
    const h = dt / f(steps);
    for (0..steps) |_| {
        for (0..4) |i| {
            const w = rate[i];
            for (0..2) |ax| {
                const goal = (if (ax == 0) tgx else tgy) + OFF[i][ax];
                cvel[i][ax] += (w * w * (goal - corner[i][ax]) - 2 * w * cvel[i][ax]) * h;
                corner[i][ax] += cvel[i][ax] * h;
            }
        }
        // press: ω 30, ζ 0.5 toward the held key; a little bounce on release is what makes it a key
        pressV += (900 * (pressGoal - press) - 30 * pressV) * h;
        press += pressV * h;
        recoilV += (-2500 * recoil - 2 * 0.3 * 50 * recoilV) * h;
        recoil += recoilV * h;
        shVX += (-1600 * shX - 2 * 0.35 * 40 * shVX) * h;
        shVY += (-1600 * shY - 2 * 0.35 * 40 * shVY) * h;
        shX += shVX * h;
        shY += shVY * h;
    }
    const moving = !settled();
    if (!moving) for (0..4) |i| {
        corner[i] = .{ tgx + OFF[i][0], tgy + OFF[i][1] };
        cvel[i] = .{ 0, 0 };
    };
    const springing = @abs(press - pressGoal) > 0.003 or @abs(pressV) > 0.03 or @abs(recoil) > 0.05 or @abs(recoilV) > 0.5 or
        @abs(shX) > 0.05 or @abs(shY) > 0.05 or @abs(shVX) > 0.5 or @abs(shVY) > 0.5;
    if (!springing) {
        press = pressGoal;
        pressV = 0;
        recoil = 0;
        recoilV = 0;
        shX = 0;
        shY = 0;
        shVX = 0;
        shVY = 0;
    }

    stepField(dt);
    var i: usize = 0;
    while (i < nwaves) {
        waves[i].t += dt;
        if (waves[i].t > 0.55) {
            for (i + 1..nwaves) |j| waves[j - 1] = waves[j];
            nwaves -= 1;
        } else i += 1;
    }
    i = 0;
    while (i < nsweeps) {
        sweeps[i].t += dt;
        if (sweeps[i].t > SWEEP_T + 0.05) {
            for (i + 1..nsweeps) |j| sweeps[j - 1] = sweeps[j];
            nsweeps -= 1;
        } else i += 1;
    }
    i = 0;
    while (i < npops) {
        pops[i].t += dt;
        if (pops[i].t > 0.55) {
            pops[i] = pops[npops - 1];
            npops -= 1;
        } else i += 1;
    }
    i = 0;
    while (i < nlocks) {
        locks[i].t += dt;
        const life: f32 = if (locks[i].kind == 2) 0.7 else 2.0;
        if (locks[i].t > life) {
            for (i + 1..nlocks) |j| locks[j - 1] = locks[j];
            nlocks -= 1;
        } else i += 1;
    }

    const now = fxRect();
    var dirty = pending;
    dirty.merge(prevFx);
    dirty.merge(now);
    prevFx = now;
    pending = .{};
    if (full) dirty = .{ .x0 = 0, .y0 = 0, .x1 = W, .y1 = H };
    full = false;

    var drew: u32 = 0;
    dirty.x0 = @max(dirty.x0, 0);
    dirty.y0 = @max(dirty.y0, 0);
    dirty.x1 = @min(dirty.x1, W);
    dirty.y1 = @min(dirty.y1, H);
    if (!dirty.empty()) {
        render(dirty);
        out = dirty;
        drew = 1;
    }
    const busy = moving or springing or nwaves > 0 or nsweeps > 0 or (ax1 > ax0) or nrip > 0 or nfish > 0 or nstreak > 0 or npops > 0 or nlocks > 0 or @abs(scrollGoal - scroll) > 0;
    return drew | (@as(u32, @intFromBool(busy)) << 1);
}
