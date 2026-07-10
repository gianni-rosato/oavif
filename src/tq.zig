const std = @import("std");

const fmetrics = @import("fmetrics");
const io = @import("io.zig");

const print = std.debug.print;
const EncCtx = @import("main.zig").EncCtx;

// TQ context
pub const TQCtx = struct {
    num_pass: usize = 0, // which pass we are on
    score: f64 = 0.0, // current score
};

// TQ pass result
const PassResult = struct {
    q: u32, // Q used
    score: f64, // score result
};

fn computeScoreAtQuality(e: *EncCtx, allocator: std.mem.Allocator) !f64 {
    var avif_data = try std.ArrayListAligned(u8, null).initCapacity(allocator, 0);
    errdefer avif_data.deinit(allocator);
    try io.encodeAvifToBuffer(e, allocator, &avif_data);

    const decoded_rgb = try io.decodeAvifToRgb(allocator, avif_data.items);
    defer allocator.free(decoded_rgb);

    e.t.num_pass += 1;

    if (e.buf.data) |*old_data|
        old_data.deinit(allocator);
    e.buf.data = avif_data;
    e.buf.q = e.q;
    e.buf.size = avif_data.items.len;

    const ref = try fmetrics.Image.init(e.rgb, e.w, e.h);
    const dst = try fmetrics.Image.init(decoded_rgb, e.w, e.h);
    return try fmetrics.ssimu2(ref, dst);
}

inline fn predictQFromScore(tgt: f64) u32 {
    const q = 6.83 * @exp(0.0282 * tgt);
    return @intFromFloat(@min(100.0, @round(q)));
}

inline fn linearInterpolate(scores: []const f64, qualities: []const f64, target: f64) ?f64 {
    if (scores.len < 2) return null;
    if (scores[1] == scores[0]) return null;

    const t = (target - scores[0]) / (scores[1] - scores[0]);
    return qualities[0] + (qualities[1] - qualities[0]) * t;
}

inline fn quadraticInterpolate(scores: []const f64, qualities: []const f64, target: f64) ?f64 {
    if (scores.len < 3) return null;

    const x0 = scores[0];
    const x1 = scores[1];
    const x2 = scores[2];
    const y0 = qualities[0];
    const y1 = qualities[1];
    const y2 = qualities[2];

    const denom = (x0 - x1) * (x0 - x2) * (x1 - x2);
    if (@abs(denom) < 0.001) return null;

    const coeff_a = (x2 * (y1 - y0) + x1 * (y0 - y2) + x0 * (y2 - y1)) / denom;
    const coeff_b = (x2 * x2 * (y0 - y1) + x1 * x1 * (y2 - y0) + x0 * x0 * (y1 - y2)) / denom;
    const coeff_c = (x1 * x2 * (x1 - x2) * y0 + x2 * x0 * (x2 - x0) * y1 + x0 * x1 * (x0 - x1) * y2) / denom;

    return coeff_a * target * target + coeff_b * target + coeff_c;
}

fn interpolateQuantizer(
    allocator: std.mem.Allocator,
    lo_bound: u32,
    hi_bound: u32,
    history: []const PassResult,
    target: f64,
) !u32 {
    const binary_search = @divFloor(lo_bound + hi_bound, 2);

    if (history.len == 0)
        return binary_search;

    var sorted = try std.ArrayList(PassResult).initCapacity(allocator, history.len);
    defer sorted.deinit(allocator);
    try sorted.appendSlice(allocator, history);

    std.mem.sort(PassResult, sorted.items, {}, struct {
        fn lessThan(_: void, lhs: PassResult, rhs: PassResult) bool {
            return lhs.score < rhs.score;
        }
    }.lessThan);

    var scores = try std.ArrayList(f64).initCapacity(allocator, 0);
    defer scores.deinit(allocator);
    var qualities = try std.ArrayList(f64).initCapacity(allocator, 0);
    defer qualities.deinit(allocator);

    for (sorted.items) |i| {
        try scores.append(allocator, i.score);
        try qualities.append(allocator, @floatFromInt(i.q));
    }

    const pred = switch (history.len) {
        1 => binary_search,
        2 => blk: {
            if (linearInterpolate(scores.items, qualities.items, target)) |r|
                break :blk @as(u32, @intFromFloat(std.math.clamp(@round(r), 0, 100)));
            break :blk binary_search;
        },
        else => blk: {
            if (quadraticInterpolate(scores.items, qualities.items, target)) |r|
                break :blk @as(u32, @intFromFloat(std.math.clamp(@round(r), 0, 100)));
            if (linearInterpolate(scores.items, qualities.items, target)) |lr|
                break :blk @as(u32, @intFromFloat(std.math.clamp(@round(lr), 0, 100)));
            break :blk binary_search;
        },
    };

    return std.math.clamp(pred, lo_bound, hi_bound);
}

pub fn findTargetQuality(
    e: *EncCtx,
    allocator: std.mem.Allocator,
) !void {
    const o = &e.o;

    var history = try std.ArrayList(PassResult).initCapacity(allocator, 0);
    defer history.deinit(allocator);
    var lo_bound: u32 = 0;
    var hi_bound: u32 = 100;

    for (0..o.max_pass) |pass| {
        e.q = if (pass == 0)
            predictQFromScore(o.score_tgt)
        else
            try interpolateQuantizer(allocator, lo_bound, hi_bound, history.items, o.score_tgt);

        if (blk: {
            for (history.items) |h|
                if (h.q == e.q)
                    break :blk true;
            break :blk false;
        }) { // quality already probed, stop
            break;
        }

        e.t.score = try computeScoreAtQuality(e, allocator);
        try history.append(allocator, PassResult{ .q = e.q, .score = e.t.score });

        // bound search based on error range
        const abs_err = @abs(e.t.score - o.score_tgt);
        if (pass == 0) {
            const err_bound: u32 = @intFromFloat(@ceil(abs_err) * 4.0);
            if (e.t.score - o.score_tgt > 0) {
                hi_bound = e.q;
                lo_bound = if (e.q > err_bound) e.q - err_bound else 0;
            } else {
                lo_bound = e.q;
                hi_bound = @min(100, e.q + err_bound);
            }
        }

        // we hit the target, exit
        if (abs_err < o.tolerance)
            return;

        // if current score > target, set as upper bound; else as lower bound
        if (pass > 0) {
            if (e.t.score > o.score_tgt)
                hi_bound = e.q
            else
                lo_bound = e.q;
        }

        // search range collapsed, exit
        if (lo_bound >= hi_bound - 1)
            break;
    }

    var best_q: ?u32 = null;
    var best_score: f64 = 0;
    var highest_q: u32 = 0;
    var highest_score: f64 = 0;

    for (history.items) |h| {
        if (h.score >= o.score_tgt and (best_q == null or h.q < best_q.?)) {
            best_q = h.q;
            best_score = h.score;
        }
        if (@max(h.score, 0) >= highest_score) {
            highest_score = h.score;
            highest_q = h.q;
        }
    }

    // pick lowest q that beats target
    if (best_q) |q| {
        e.q = q;
        e.t.score = best_score;
        return;
    }

    // no pass met target, use highest scoring q
    e.q = highest_q;
    e.t.score = highest_score;
    return;
}
