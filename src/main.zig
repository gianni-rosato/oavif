const std = @import("std");

const io = @import("io.zig");
const a = @import("parse_args.zig");
const tq = @import("tq.zig");

const print = std.debug.print;
const VERSION = @import("build_opts").version;

// AVIF encoded data buffer
const EncBuffer = struct {
    q: ?u32 = null, // Q used
    data: ?std.ArrayList(u8) = null, // AVIF
    size: usize = 0, // data size

    pub fn deinitCache(buf: *EncBuffer, allocator: std.mem.Allocator) void {
        if (buf.data) |*data| {
            data.deinit(allocator);
            buf.data = null;
        }
        buf.q = null;
    }
};

// Encoder Context
pub const EncCtx = struct {
    o: a.AvifEncOptions = a.AvifEncOptions{}, // user options
    t: tq.TQCtx = tq.TQCtx{}, // TQ context
    q: u32 = 0, // final chosen Q, updated in-loop
    w: u32 = 0, // input width
    h: u32 = 0, // input height
    rgb: []const u8 = undefined, // decoded 8-bit input RGB buffer
    src: io.Image = undefined, // input image
    buf: EncBuffer = EncBuffer{}, // compressed AVIF
};

pub fn main(init: std.process.Init) !void {
    print("\x1b[31moavif\x1b[0m | {s}\n", .{VERSION});
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    while (args_iter.next()) |arg|
        try args.append(allocator, try allocator.dupe(u8, arg));

    var show_help = false;
    var show_version = false;
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;

    for (1..args.items.len) |i| {
        const arg = args.items[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))
            show_help = true
        else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v"))
            show_version = true
        else
            break;
    }

    if (show_help) return a.printUsage();
    if (show_version) return io.printVersion(VERSION);

    var e: EncCtx = EncCtx{};
    try e.o.parseArgs(args.items, &input_file, &output_file);
    const o = &e.o;

    const input_path =
        if (input_file) |in| in else return error.MissingInputOrOutput;
    const output_path =
        if (output_file) |out| out else return error.MissingInputOrOutput;

    e.src = try io.loadImage(init.io, allocator, input_path);
    defer e.src.deinit(allocator);
    const src = &e.src;

    const in_depth: u8 = if (src.hbd) 16 else 8;
    print("Read {}x{}, {s}, {}-bit, {} bytes\n", .{
        src.width,
        src.height,
        if (src.channels > 3) "RGBA" else "RGB",
        in_depth,
        (try std.Io.Dir.cwd().statFile(init.io, input_file.?, .{})).size,
    });

    e.rgb = if (e.src.channels == 3 and !e.src.hbd) src.data else try src.toRGB8(allocator);
    defer if (!(e.src.channels == 3 and !e.src.hbd)) allocator.free(e.rgb);
    e.w = @intCast(e.src.width);
    e.h = @intCast(e.src.height);

    const out_depth: u8 = if (o.tenbit) 10 else if (e.src.hbd) 10 else 8;

    if (o.quality) |q| { // bypass TQ
        e.q = q;
        print("Encoding [q{}, speed {}, {}-bit]\n", .{ q, o.speed, out_depth });
        try io.encodeAvifToFile(&e, init.io, allocator, output_path);
        const bpp: f64 = @as(f64, @floatFromInt(e.buf.size * 8)) / @as(f64, @floatFromInt(e.w * e.h));
        print("Compressed to {} bytes ({d:.3} bpp)\n", .{ e.buf.size, bpp });
        return;
    }

    print("Searching [tgt {}±{d:.1}, speed {}, {}-bit]\n", .{ o.score_tgt, o.tolerance, o.speed, out_depth });
    try tq.findTargetQuality(&e, allocator);
    defer e.buf.deinitCache(allocator);
    const buf = &e.buf;
    print("Found q{} (score {d:.2}, {} passes)\n", .{ e.q, e.t.score, e.t.num_pass });

    // if we have a buffer at the best Q, write
    if (buf.q.? == e.q) {
        const file = try std.Io.Dir.cwd().createFile(init.io, output_path, .{});
        defer file.close(init.io);
        var write_buffer: [8192]u8 = undefined;
        var writer = file.writerStreaming(init.io, &write_buffer);
        try writer.interface.writeAll(buf.data.?.items);
        try writer.interface.flush();
    } else try io.encodeAvifToFile(&e, init.io, allocator, output_path);

    const bpp: f64 = @as(f64, @floatFromInt(e.buf.size * 8)) / @as(f64, @floatFromInt(e.w * e.h));
    print("Compressed to {} bytes ({d:.3} bpp)\n", .{ e.buf.size, bpp });
}
