const std = @import("std");

const c = @cImport({
    @cInclude("avif/avif.h");
});

const print = std.debug.print;

const ARG_SPEED: [:0]const u8 = "--speed";
const ARG_SCORE_TGT: [:0]const u8 = "--score-tgt";
const ARG_QUALITY_ALPHA: [:0]const u8 = "--quality-alpha";
const ARG_MAX_THREADS: [:0]const u8 = "--max-threads";
const ARG_TILE_ROWS_LOG2: [:0]const u8 = "--tile-rows-log2";
const ARG_TILE_COLS_LOG2: [:0]const u8 = "--tile-cols-log2";
const ARG_AUTO_TILING: [:0]const u8 = "--auto-tiling";
const ARG_TUNE: [:0]const u8 = "--tune";
const ARG_TENBIT: [:0]const u8 = "--tenbit";
const ARG_TOLERANCE: [:0]const u8 = "--tolerance";
const ARG_MAX_PASS: [:0]const u8 = "--max-pass";
const ARG_QUALITY: [:0]const u8 = "--quality";
const ARG_COLOR_PRIMARIES: [:0]const u8 = "--color-primaries";
const ARG_TRANSFER_CHARACTERISTICS: [:0]const u8 = "--transfer-characteristics";
const ARG_MATRIX_COEFFICIENTS: [:0]const u8 = "--matrix-coefficients";

// libaom image tune
pub const TuneMode = enum {
    ssim,
    iq,
    ssimulacra2,

    pub fn toString(self: TuneMode) [:0]const u8 {
        return switch (self) {
            .ssim => "ssim",
            .iq => "iq",
            .ssimulacra2 => "ssimulacra2",
        };
    }

    pub fn fromString(s: []const u8) !TuneMode {
        if (std.mem.eql(u8, s, "ssim")) return .ssim;
        if (std.mem.eql(u8, s, "iq")) return .iq;
        if (std.mem.eql(u8, s, "ssimulacra2")) return .ssimulacra2;
        return error.InvalidTuneMode;
    }
};

// AVIF encoder options – see help menu for member info
pub const AvifEncOptions = struct {
    quality_alpha: u8 = 0,
    speed: u8 = 9,
    max_threads: u8 = 1,
    tile_rows_log2: u8 = 0,
    tile_cols_log2: u8 = 0,
    auto_tiling: bool = true,
    score_tgt: f64 = 80.0,
    tenbit: bool = true,
    tune: TuneMode = .iq,
    tolerance: f64 = 2.0,
    max_pass: u8 = 6,
    quality: ?u32 = null,
    color_primaries: u8 = 2,
    transfer_characteristics: u8 = 2,
    matrix_coefficients: u8 = 2,

    pub fn copyToEncoder(options: *const AvifEncOptions, encoder: *c.avifEncoder) !void {
        encoder.qualityAlpha = options.quality_alpha;
        encoder.speed = options.speed;
        encoder.maxThreads = options.max_threads;
        encoder.tileRowsLog2 = options.tile_rows_log2;
        encoder.tileColsLog2 = options.tile_cols_log2;
        encoder.autoTiling = @intFromBool(options.auto_tiling);
        if (c.avifEncoderSetCodecSpecificOption(encoder, "tune", options.tune.toString()) != c.AVIF_RESULT_OK)
            return error.InvalidCodecOption;
    }

    pub fn parseArgs(o: *AvifEncOptions, args: []const []const u8, input_file: *?[]const u8, output_file: *?[]const u8) !void {
        var arg_idx: usize = 1;

        while (arg_idx < args.len) {
            const arg = args[arg_idx];
            arg_idx += 1;

            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, ARG_SPEED)) {
                o.speed = @intCast(try intCliArg(&arg_idx, args, 0, 10, ARG_SPEED));
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, ARG_SCORE_TGT)) {
                o.score_tgt = try floatCliArg(&arg_idx, args, 30.0, 100.0, ARG_SCORE_TGT);
            } else if (std.mem.eql(u8, arg, ARG_QUALITY_ALPHA)) {
                o.quality_alpha = @intCast(try intCliArg(&arg_idx, args, 0, 99, ARG_QUALITY_ALPHA));
            } else if (std.mem.eql(u8, arg, ARG_MAX_THREADS)) {
                o.max_threads = @intCast(try intCliArg(&arg_idx, args, 1, 255, ARG_MAX_THREADS));
            } else if (std.mem.eql(u8, arg, ARG_TILE_ROWS_LOG2)) {
                o.tile_rows_log2 = @intCast(try intCliArg(&arg_idx, args, 0, 6, ARG_TILE_ROWS_LOG2));
            } else if (std.mem.eql(u8, arg, ARG_TILE_COLS_LOG2)) {
                o.tile_cols_log2 = @intCast(try intCliArg(&arg_idx, args, 0, 6, ARG_TILE_COLS_LOG2));
            } else if (std.mem.eql(u8, arg, ARG_AUTO_TILING)) {
                o.auto_tiling = try boolCliArg(&arg_idx, args, ARG_AUTO_TILING);
            } else if (std.mem.eql(u8, arg, ARG_TUNE)) {
                o.tune = try tuneCliArg(&arg_idx, args, ARG_TUNE);
            } else if (std.mem.eql(u8, arg, ARG_TENBIT)) {
                o.tenbit = try boolCliArg(&arg_idx, args, ARG_TENBIT);
            } else if (std.mem.eql(u8, arg, ARG_TOLERANCE)) {
                o.tolerance = try floatCliArg(&arg_idx, args, 1.0, 100.0, ARG_TOLERANCE);
            } else if (std.mem.eql(u8, arg, ARG_MAX_PASS)) {
                o.max_pass = @intCast(try intCliArg(&arg_idx, args, 1, 12, ARG_MAX_PASS));
            } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, ARG_QUALITY)) {
                o.quality = @intCast(try intCliArg(&arg_idx, args, 0, 100, ARG_QUALITY));
            } else if (std.mem.eql(u8, arg, ARG_COLOR_PRIMARIES)) {
                o.color_primaries = @intCast(try intCliArg(&arg_idx, args, 1, 22, ARG_COLOR_PRIMARIES));
            } else if (std.mem.eql(u8, arg, ARG_TRANSFER_CHARACTERISTICS)) {
                o.transfer_characteristics = @intCast(try intCliArg(&arg_idx, args, 1, 18, ARG_TRANSFER_CHARACTERISTICS));
            } else if (std.mem.eql(u8, arg, ARG_MATRIX_COEFFICIENTS)) {
                o.matrix_coefficients = @intCast(try intCliArg(&arg_idx, args, 0, 14, ARG_MATRIX_COEFFICIENTS));
            } else if (input_file.* == null) {
                input_file.* = arg;
            } else if (output_file.* == null) {
                output_file.* = arg;
            } else {
                print("Error: Unexpected argument: {s}\n", .{arg});
                return error.UnexpectedArgument;
            }
        }
    }
};

fn intCliArg(arg_idx: *usize, args: []const []const u8, min: i64, max: i64, arg: [:0]const u8) !i64 {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tmp: i64 = try std.fmt.parseInt(i64, args[arg_idx.*], 10);
    if (tmp < min or tmp > max) {
        print("Error: {s} must be between {d} and {d}\n", .{ arg, min, max });
        return error.InvalidOptionValue;
    }
    arg_idx.* += 1;
    return tmp;
}

fn floatCliArg(arg_idx: *usize, args: []const []const u8, min: f64, max: f64, arg: [:0]const u8) !f64 {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tmp: f64 = try std.fmt.parseFloat(f64, args[arg_idx.*]);
    if (tmp < min or tmp > max) {
        print("Error: {s} must be between {d} and {d}\n", .{ arg, min, max });
        return error.InvalidOptionValue;
    }
    arg_idx.* += 1;
    return tmp;
}

fn boolCliArg(arg_idx: *usize, args: []const []const u8, arg: [:0]const u8) !bool {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tmp: i32 = try std.fmt.parseInt(i32, args[arg_idx.*], 10);
    if (tmp != 0 and tmp != 1) {
        print("Error: {s} must be 0 or 1\n", .{arg});
        return error.InvalidOptionValue;
    }
    arg_idx.* += 1;
    return tmp == 1;
}

fn tuneCliArg(arg_idx: *usize, args: []const []const u8, arg: [:0]const u8) !TuneMode {
    if (arg_idx.* >= args.len or args[arg_idx.*][0] == '-') {
        print("Error: Missing {s} value\n", .{arg});
        return error.MissingOptionValue;
    }
    const tune_mode = TuneMode.fromString(args[arg_idx.*]) catch {
        print("Error: {s} must be one of: ssim, iq, ssimulacra2\n", .{arg});
        return error.InvalidOptionValue;
    };
    arg_idx.* += 1;
    return tune_mode;
}

pub fn printUsage() void {
    const d: AvifEncOptions = AvifEncOptions{};
    print("\n", .{});
    print(
        \\usage:  oavif [options] <in> <out.avif>
        \\
        \\options:
        \\ -h, --help
        \\    show this help
        \\ -v, --version
        \\    show version information
        \\ -s, --speed u8
        \\    encoder speed (0..10) [{d}]
        \\ -t, --score-tgt f64
        \\    target SSIMULACRA2 score (0..100) [{d:.0}]
        \\ --quality-alpha u8
        \\    quality factor for alpha (0..100=lossless) [{d}]
        \\ --max-threads u8
        \\    maximum number of threads to use (1..255) [{d}]
        \\ --tile-rows-log2 u8
        \\    tile rows log2 (0..6) [{d}]
        \\ --tile-cols-log2 u8
        \\    tile columns log2 (0..6) [{d}]
        \\ --auto-tiling 0/1
        \\    enable automatic tiling [{d}]
        \\ --tune str
        \\    libaom tuning mode (ssim, iq, ssimulacra2) [{s}]
        \\ --tenbit 0/1
        \\    force 10-bit AVIF output [{d}]
        \\ --tolerance f64
        \\    target quality error tolerance (1..100) [{d:.0}]
        \\ --max-pass u8
        \\    maximum search passes (1..12) [{d}]
        \\ -q, --quality u8
        \\    quantizer (0..100), bypasses search
        \\ --color-primaries u8
        \\    color primaries (1..22) [{d}]
        \\ --transfer-characteristics u8
        \\    transfer characteristics (1..18) [{d}]
        \\ --matrix-coefficients u8
        \\    matrix coefficients (0..14) [{d}]
    , .{
        d.speed,
        d.score_tgt,
        d.quality_alpha,
        d.max_threads,
        d.tile_rows_log2,
        d.tile_cols_log2,
        @intFromBool(d.auto_tiling),
        d.tune.toString(),
        @intFromBool(d.tenbit),
        d.tolerance,
        d.max_pass,
        d.color_primaries,
        d.transfer_characteristics,
        d.matrix_coefficients,
    });
    print("\n\n\x1b[37msRGB PNG, PNM/PAM, or QOI input expected\x1b[0m\n", .{});
}
