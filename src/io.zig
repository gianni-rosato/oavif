const std = @import("std");
const imgio = @import("simpleimgio");

const c = @cImport({
    @cInclude("spng.h");
    @cInclude("avif/avif.h");
});

const EncCtx = @import("main.zig").EncCtx;
const print = std.debug.print;

pub fn printVersion(version: []const u8) void {
    const avif_major: comptime_int = c.AVIF_VERSION_MAJOR;
    const avif_minor: comptime_int = c.AVIF_VERSION_MINOR;
    const avif_patch: comptime_int = c.AVIF_VERSION_PATCH;

    print("oavif {s}\n", .{version});
    print("libavif {d}.{d}.{d} (", .{ avif_major, avif_minor, avif_patch });

    var ver_buf: [256]u8 = undefined;
    c.avifCodecVersions(&ver_buf);
    const ver_str = std.mem.span(@as([*:0]u8, @ptrCast(&ver_buf)));
    print("{s})\n", .{ver_str});
}

// Image data structure
pub const Image = struct {
    width: usize,
    height: usize,
    channels: u8, // 1=Gray,2=GrayA,3=RGB,4=RGBA
    hbd: bool, // high bit depth (16-bit)
    data: []u8, // interleaved, row-major
    icc: ?[]u8 = null, // ICC color profile data
    exif: ?[]u8 = null,
    xmp: ?[]u8 = null,

    pub fn deinit(img: *Image, allocator: std.mem.Allocator) void {
        allocator.free(img.data);
        if (img.icc) |icc| allocator.free(icc);
        if (img.exif) |exif| allocator.free(exif);
        if (img.xmp) |xmp| allocator.free(xmp);
        img.* = undefined;
    }

    pub fn toRGB8(img: *Image, allocator: std.mem.Allocator) ![]u8 {
        const pixels = img.width * img.height;
        const rgb = try allocator.alloc(u8, pixels * 3);

        if (img.hbd) {
            // downscale to 8-bit
            const src_u16 = @as([*]const u16, @ptrCast(@alignCast(img.data.ptr)));
            switch (img.channels) {
                3 => {
                    for (0..pixels) |i| {
                        rgb[i * 3 + 0] = @intCast(src_u16[i * 3 + 0] >> 8);
                        rgb[i * 3 + 1] = @intCast(src_u16[i * 3 + 1] >> 8);
                        rgb[i * 3 + 2] = @intCast(src_u16[i * 3 + 2] >> 8);
                    }
                },
                4 => {
                    for (0..pixels) |i| {
                        rgb[i * 3 + 0] = @intCast(src_u16[i * 4 + 0] >> 8);
                        rgb[i * 3 + 1] = @intCast(src_u16[i * 4 + 1] >> 8);
                        rgb[i * 3 + 2] = @intCast(src_u16[i * 4 + 2] >> 8);
                    }
                },
                1 => {
                    for (0..pixels) |i| {
                        const g: u8 = @intCast(src_u16[i] >> 8);
                        rgb[i * 3 + 0] = g;
                        rgb[i * 3 + 1] = g;
                        rgb[i * 3 + 2] = g;
                    }
                },
                2 => {
                    for (0..pixels) |i| {
                        const g: u8 = @intCast(src_u16[i * 2 + 0] >> 8);
                        rgb[i * 3 + 0] = g;
                        rgb[i * 3 + 1] = g;
                        rgb[i * 3 + 2] = g;
                    }
                },
                else => return error.UnsupportedChannelCount,
            }
        } else {
            switch (img.channels) {
                3 => {
                    for (0..pixels) |i| {
                        rgb[i * 3 + 0] = img.data[i * 3 + 0];
                        rgb[i * 3 + 1] = img.data[i * 3 + 1];
                        rgb[i * 3 + 2] = img.data[i * 3 + 2];
                    }
                },
                4 => {
                    for (0..pixels) |i| {
                        rgb[i * 3 + 0] = img.data[i * 4 + 0];
                        rgb[i * 3 + 1] = img.data[i * 4 + 1];
                        rgb[i * 3 + 2] = img.data[i * 4 + 2];
                    }
                },
                1 => {
                    for (0..pixels) |i| {
                        const g = img.data[i];
                        rgb[i * 3 + 0] = g;
                        rgb[i * 3 + 1] = g;
                        rgb[i * 3 + 2] = g;
                    }
                },
                2 => {
                    for (0..pixels) |i| {
                        const g = img.data[i * 2 + 0];
                        rgb[i * 3 + 0] = g;
                        rgb[i * 3 + 1] = g;
                        rgb[i * 3 + 2] = g;
                    }
                },
                else => return error.UnsupportedChannelCount,
            }
        }
        return rgb;
    }
};

pub fn loadImage(io_ctx: std.Io, allocator: std.mem.Allocator, path: []const u8) !Image {
    const buf = try std.Io.Dir.cwd().readFileAlloc(io_ctx, path, allocator, .unlimited);
    defer allocator.free(buf);

    if (isPng(buf))
        return loadPNG(allocator, buf);

    if (isNetpbm(buf)) {
        var netpbm = try imgio.decodePnmBytes(allocator, buf);
        errdefer netpbm.deinit(allocator);
        return fromSimpleImage(allocator, &netpbm);
    }

    return error.UnsupportedImageFormat;
}

fn isPng(buf: []const u8) bool {
    return buf.len >= 8 and std.mem.eql(u8, buf[0..8], "\x89PNG\r\n\x1A\n");
}

fn isNetpbm(buf: []const u8) bool {
    return buf.len >= 2 and buf[0] == 'P' and buf[1] >= '1' and buf[1] <= '7';
}

fn fromSimpleImage(allocator: std.mem.Allocator, simple: *imgio.Image) !Image {
    if (simple.depth < 1 or simple.depth > 4)
        return error.UnsupportedChannelCount;

    if (simple.maxval <= 255) {
        var eight = try simple.to8BitOwned(allocator);
        errdefer eight.deinit(allocator);

        const data = eight.data;
        eight.data = &.{};
        return .{
            .width = eight.width,
            .height = eight.height,
            .channels = eight.depth,
            .hbd = false,
            .data = data,
        };
    }

    defer simple.deinit(allocator);

    const samples = try simple.sampleCount();
    if (simple.data.len != samples * 2)
        return error.BadImageData;

    const data = try allocator.alloc(u8, samples * 2);
    errdefer allocator.free(data);

    for (0..samples) |i| {
        const src_idx = i * 2;
        const sample = std.mem.readInt(u16, simple.data[src_idx..][0..2], .big);
        const scaled: u16 = @intCast((@as(u64, @min(sample, simple.maxval)) * 65535 + simple.maxval / 2) / simple.maxval);
        std.mem.writeInt(u16, data[src_idx..][0..2], scaled, .native);
    }

    return .{
        .width = simple.width,
        .height = simple.height,
        .channels = simple.depth,
        .hbd = true,
        .data = data,
    };
}

pub fn loadPNG(allocator: std.mem.Allocator, buf: []const u8) !Image {
    const ctx = c.spng_ctx_new(0);
    if (ctx == null) return error.FailedCreateContext;
    defer c.spng_ctx_free(ctx);

    if (c.spng_set_png_buffer(ctx, buf.ptr, buf.len) != 0)
        return error.SetBufferFailed;

    var ihdr: c.struct_spng_ihdr = undefined;
    if (c.spng_get_ihdr(ctx, &ihdr) != 0)
        return error.GetHeaderFailed;

    var icc_profile: ?[]u8 = null;
    var iccp: c.struct_spng_iccp = undefined;
    if (c.spng_get_iccp(ctx, &iccp) == 0)
        if (iccp.profile_len > 0 and iccp.profile != null) {
            icc_profile = try allocator.alloc(u8, iccp.profile_len);
            @memcpy(icc_profile.?, iccp.profile[0..iccp.profile_len]);
        };

    const is_16bit = ihdr.bit_depth == 16;
    const fmt: c_int = if (is_16bit) blk: {
        break :blk c.SPNG_FMT_RGBA16;
    } else blk: {
        break :blk switch (ihdr.color_type) {
            c.SPNG_COLOR_TYPE_TRUECOLOR => c.SPNG_FMT_RGB8,
            c.SPNG_COLOR_TYPE_TRUECOLOR_ALPHA => c.SPNG_FMT_RGBA8,
            c.SPNG_COLOR_TYPE_GRAYSCALE => c.SPNG_FMT_RGBA8,
            c.SPNG_COLOR_TYPE_GRAYSCALE_ALPHA => c.SPNG_FMT_RGBA8,
            c.SPNG_COLOR_TYPE_INDEXED => c.SPNG_FMT_RGBA8,
            else => c.SPNG_FMT_RGBA8,
        };
    };

    var out_size: usize = 0;
    if (c.spng_decoded_image_size(ctx, fmt, &out_size) != 0) return error.ImageSizeFailed;

    const out_buf = try allocator.alloc(u8, out_size);
    errdefer {
        allocator.free(out_buf);
        if (icc_profile) |icc| allocator.free(icc);
    }

    if (c.spng_decode_image(ctx, out_buf.ptr, out_size, fmt, 0) != 0) {
        if (icc_profile) |icc| allocator.free(icc);
        return error.DecodeFailed;
    }

    var exif_data: ?[]u8 = null;
    var png_exif: c.struct_spng_exif = undefined;
    const exif_result = c.spng_get_exif(ctx, &png_exif);
    if (exif_result == 0) {
        if (png_exif.length > 0 and png_exif.data != null) {
            exif_data = try allocator.alloc(u8, png_exif.length);
            errdefer allocator.free(exif_data.?);
            @memcpy(exif_data.?, png_exif.data[0..png_exif.length]);
        }
    }

    var xmp_data: ?[]u8 = null;

    var n_text: u32 = 0;
    var text_result = c.spng_get_text(ctx, null, &n_text);

    if (text_result == 0 and n_text > 0) {
        const text_chunks = try allocator.alloc(c.struct_spng_text, n_text);
        defer allocator.free(text_chunks);

        text_result = c.spng_get_text(ctx, text_chunks.ptr, &n_text);

        if (text_result == 0) {
            for (text_chunks[0..n_text]) |text_chunk| {
                const keyword_len = std.mem.indexOfScalar(u8, &text_chunk.keyword, 0) orelse text_chunk.keyword.len;
                const keyword = text_chunk.keyword[0..keyword_len];

                if (text_chunk.type == c.SPNG_ITXT or text_chunk.type == c.SPNG_TEXT or text_chunk.type == c.SPNG_ZTXT) {
                    if (std.mem.eql(u8, keyword, "XML:com.adobe.xmp")) {
                        const text_len = std.mem.len(text_chunk.text);
                        if (text_len > 0) {
                            xmp_data = try allocator.alloc(u8, text_len);
                            errdefer allocator.free(xmp_data.?);
                            @memcpy(xmp_data.?, text_chunk.text[0..text_len]);
                        }
                        break;
                    } else if (std.mem.eql(u8, keyword, "Raw profile type xmp")) {
                        const raw = @as([*]const u8, @ptrCast(text_chunk.text))[0..@as(usize, @intCast(text_chunk.length))];

                        var verbatim_start: ?usize = null;
                        var verbatim_end: ?usize = null;

                        if (std.mem.indexOf(u8, raw, "<x:xmpmeta")) |start_idx| {
                            verbatim_start = start_idx;
                            if (std.mem.indexOfPos(u8, raw, start_idx, "</x:xmpmeta>")) |end_tag_idx|
                                verbatim_end = end_tag_idx + "</x:xmpmeta>".len
                            else
                                verbatim_end = raw.len;
                        } else if (std.mem.indexOf(u8, raw, "<rdf:RDF")) |start_idx| {
                            verbatim_start = start_idx;
                            if (std.mem.indexOfPos(u8, raw, start_idx, "</rdf:RDF>")) |end_tag_idx|
                                verbatim_end = end_tag_idx + "</rdf:RDF>".len
                            else
                                verbatim_end = raw.len;
                        } else if (std.mem.indexOf(u8, raw, "<?xpacket")) |start_idx| {
                            verbatim_start = start_idx;
                            if (std.mem.lastIndexOf(u8, raw, "<?xpacket")) |last_tag_start| {
                                if (std.mem.indexOfPos(u8, raw, last_tag_start, "?>")) |end_tag_idx|
                                    verbatim_end = end_tag_idx + 2;
                            }
                            if (verbatim_end == null) verbatim_end = raw.len;
                        }

                        if (verbatim_start != null and verbatim_end != null) {
                            const xml = raw[verbatim_start.?..verbatim_end.?];
                            if (xml.len > 0) {
                                xmp_data = try allocator.alloc(u8, xml.len);
                                errdefer allocator.free(xmp_data.?);
                                @memcpy(xmp_data.?, xml);
                            }
                            break;
                        }

                        const is_hex = struct {
                            fn f(ch: u8) bool {
                                return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
                            }
                            fn val(ch: u8) u8 {
                                return if (ch >= '0' and ch <= '9') ch - '0' else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10 else ch - 'A' + 10;
                            }
                        }.f;
                        const hex_val = struct {
                            fn v(ch: u8) u8 {
                                return if (ch >= '0' and ch <= '9') ch - '0' else if (ch >= 'a' and ch <= 'f') ch - 'a' + 10 else ch - 'A' + 10;
                            }
                        }.v;

                        var i_scan: usize = 0;
                        var newlines: u8 = 0;
                        while (i_scan < raw.len and newlines < 3) : (i_scan += 1) {
                            if (raw[i_scan] == '\n') newlines += 1;
                        }

                        if (newlines < 3) i_scan = 0;

                        while (i_scan < raw.len and !is_hex(raw[i_scan])) : (i_scan += 1) {}
                        if (i_scan >= raw.len) continue;

                        var decoded = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
                        defer decoded.deinit(allocator);

                        var hi: ?u8 = null;
                        while (i_scan < raw.len) : (i_scan += 1) {
                            const ch = raw[i_scan];
                            if (!is_hex(ch)) continue;
                            if (hi == null)
                                hi = hex_val(ch)
                            else {
                                const b: u8 = (hi.? << 4) | hex_val(ch);
                                try decoded.append(allocator, b);
                                hi = null;
                            }
                        }

                        if (decoded.items.len == 0)
                            continue;

                        const decoded_bytes = decoded.items;

                        var xml_start_opt: ?usize = null;
                        var xml_end_opt: ?usize = null;

                        if (std.mem.indexOf(u8, decoded_bytes, "<x:xmpmeta")) |xml_start| {
                            xml_start_opt = xml_start;
                            if (std.mem.indexOfPos(u8, decoded_bytes, xml_start, "</x:xmpmeta>")) |end_tag_idx|
                                xml_end_opt = end_tag_idx + "</x:xmpmeta>".len
                            else
                                xml_end_opt = decoded_bytes.len;
                        } else if (std.mem.indexOf(u8, decoded_bytes, "<rdf:RDF")) |rdf_start| {
                            xml_start_opt = rdf_start;
                            if (std.mem.indexOfPos(u8, decoded_bytes, rdf_start, "</rdf:RDF>")) |end_tag_idx|
                                xml_end_opt = end_tag_idx + "</rdf:RDF>".len
                            else
                                xml_end_opt = decoded_bytes.len;
                        } else if (std.mem.indexOf(u8, decoded_bytes, "<?xpacket")) |start_idx| {
                            xml_start_opt = start_idx;
                            if (std.mem.lastIndexOf(u8, decoded_bytes, "<?xpacket")) |last_tag_start| {
                                if (std.mem.indexOfPos(u8, decoded_bytes, last_tag_start, "?>")) |end_tag_idx|
                                    xml_end_opt = end_tag_idx + 2;
                            }
                            if (xml_end_opt == null) xml_end_opt = decoded_bytes.len;
                        }

                        if (xml_start_opt != null and xml_end_opt != null and xml_end_opt.? > xml_start_opt.?) {
                            const xml = decoded_bytes[xml_start_opt.?..xml_end_opt.?];
                            if (xml.len > 0) {
                                xmp_data = try allocator.alloc(u8, xml.len);
                                errdefer allocator.free(xmp_data.?);
                                @memcpy(xmp_data.?, xml);
                            }
                            break;
                        }
                    }
                }
            }
        }
    }
    const channels: u8 = if (is_16bit) 4 else switch (fmt) {
        c.SPNG_FMT_RGB8 => 3,
        else => 4,
    };

    return .{
        .width = ihdr.width,
        .height = ihdr.height,
        .channels = channels,
        .hbd = is_16bit,
        .data = out_buf,
        .icc = icc_profile,
        .exif = exif_data,
        .xmp = xmp_data,
    };
}

const AvifDecodeResult = struct {
    decoder: *c.avifDecoder,
    rgb: c.avifRGBImage,
};

fn decodeAvifCommon(avif_data: []const u8, use_8bit: bool) !AvifDecodeResult {
    const decoder = c.avifDecoderCreate();
    if (decoder == null) return error.OutOfMemory;
    errdefer c.avifDecoderDestroy(decoder);

    const parse_result = c.avifDecoderSetIOMemory(decoder, avif_data.ptr, avif_data.len);
    if (parse_result != c.AVIF_RESULT_OK) return error.SetIOFailed;

    if (c.avifDecoderParse(decoder) != c.AVIF_RESULT_OK)
        return error.ParseFailed;

    if (c.avifDecoderNextImage(decoder) != c.AVIF_RESULT_OK)
        return error.DecodeImageFailed;

    const img = decoder.*.image;
    var rgb: c.avifRGBImage = undefined;
    c.avifRGBImageSetDefaults(&rgb, img);

    if (use_8bit)
        rgb.depth = 8;

    rgb.format = if (img.*.alphaPlane != null) c.AVIF_RGB_FORMAT_RGBA else c.AVIF_RGB_FORMAT_RGB;

    if (c.avifRGBImageAllocatePixels(&rgb) != c.AVIF_RESULT_OK)
        return error.AllocatePixelsFailed;

    if (c.avifImageYUVToRGB(img, &rgb) != c.AVIF_RESULT_OK)
        return error.ConvertToRGBFailed;

    return .{ .decoder = decoder.?, .rgb = rgb };
}

pub fn encodeAvifToBuffer(e: *EncCtx, allocator: std.mem.Allocator, output: *std.ArrayListAligned(u8, null)) !void {
    const o = &e.o;
    const output_depth: u32 = if (o.tenbit) 10 else if (e.src.hbd) 10 else 8;

    const image = c.avifImageCreate(e.w, e.h, output_depth, c.AVIF_PIXEL_FORMAT_YUV444);
    if (image == null) return error.OutOfMemory;
    defer c.avifImageDestroy(image);

    image.*.colorPrimaries = o.color_primaries;
    image.*.transferCharacteristics = o.transfer_characteristics;
    image.*.matrixCoefficients = o.matrix_coefficients;

    if (e.src.icc) |icc| {
        const result = c.avifImageSetProfileICC(image, icc.ptr, icc.len);
        if (result != c.AVIF_RESULT_OK)
            return error.SetICCProfileFailed;
    }

    if (e.src.exif) |exif| {
        const result = c.avifImageSetMetadataExif(image, exif.ptr, exif.len);
        if (result != c.AVIF_RESULT_OK)
            return error.SetExifFailed;

        // restore orientation instead of using the source's
        image.*.transformFlags = c.AVIF_TRANSFORM_NONE;
        image.*.imir.axis = 0;
    }

    var rgb_img = c.avifRGBImage{};
    c.avifRGBImageSetDefaults(&rgb_img, image);
    const has_alpha = e.src.channels == 2 or e.src.channels == 4;
    rgb_img.format = if (has_alpha) c.AVIF_RGB_FORMAT_RGBA else c.AVIF_RGB_FORMAT_RGB;
    const output_channels: u8 = if (has_alpha) 4 else 3;

    var gray_to_rgb: ?[]u8 = null;
    var gray_to_rgb_16: ?[]u16 = null;
    defer if (gray_to_rgb) |g| allocator.free(g);
    defer if (gray_to_rgb_16) |g| allocator.free(g);

    const work_data: []u8 = if (e.src.channels == 1 or e.src.channels == 2) blk: {
        const pixels = e.w * e.h;
        if (e.src.hbd) {
            gray_to_rgb_16 = try allocator.alloc(u16, pixels * output_channels);
            const src_u16 = @as([*]const u16, @ptrCast(@alignCast(e.src.data.ptr)));
            const dst_u16 = gray_to_rgb_16.?;

            if (e.src.channels == 1) {
                for (0..pixels) |i| {
                    const gray = src_u16[i];
                    dst_u16[i * 3 + 0] = gray;
                    dst_u16[i * 3 + 1] = gray;
                    dst_u16[i * 3 + 2] = gray;
                }
            } else {
                for (0..pixels) |i| {
                    const gray = src_u16[i * 2 + 0];
                    const alpha = src_u16[i * 2 + 1];
                    dst_u16[i * 4 + 0] = gray;
                    dst_u16[i * 4 + 1] = gray;
                    dst_u16[i * 4 + 2] = gray;
                    dst_u16[i * 4 + 3] = alpha;
                }
            }
            break :blk @as([*]u8, @ptrCast(dst_u16.ptr))[0 .. pixels * output_channels * 2];
        } else {
            gray_to_rgb = try allocator.alloc(u8, pixels * output_channels);
            const dst = gray_to_rgb.?;

            if (e.src.channels == 1) {
                for (0..pixels) |i| {
                    const gray = e.src.data[i];
                    dst[i * 3 + 0] = gray;
                    dst[i * 3 + 1] = gray;
                    dst[i * 3 + 2] = gray;
                }
            } else {
                for (0..pixels) |i| {
                    const gray = e.src.data[i * 2 + 0];
                    const alpha = e.src.data[i * 2 + 1];
                    dst[i * 4 + 0] = gray;
                    dst[i * 4 + 1] = gray;
                    dst[i * 4 + 2] = gray;
                    dst[i * 4 + 3] = alpha;
                }
            }
            break :blk dst;
        }
    } else e.src.data;

    const work_channels = output_channels;

    if (!e.src.hbd and output_depth == 10) {
        const pixels = e.w * e.h;
        const scaled_data = try allocator.alloc(u16, pixels * work_channels);
        defer allocator.free(scaled_data);

        for (0..pixels * work_channels) |i|
            scaled_data[i] = @intCast((@as(usize, work_data[i]) * 1023 + 127) / 255);

        rgb_img.pixels = @ptrCast(scaled_data.ptr);
        rgb_img.rowBytes = e.w * work_channels * 2;
        rgb_img.depth = 10;

        if (c.avifImageRGBToYUV(image, &rgb_img) != c.AVIF_RESULT_OK)
            return error.ConvertFailed;
    } else if (e.src.hbd and output_depth == 10) {
        const pixels = e.w * e.h;
        const scaled_data = try allocator.alloc(u16, pixels * work_channels);
        defer allocator.free(scaled_data);

        const src_u16 = @as([*]const u16, @ptrCast(@alignCast(work_data.ptr)))[0 .. pixels * work_channels];
        for (0..pixels * work_channels) |i|
            scaled_data[i] = src_u16[i] >> 6;

        rgb_img.pixels = @ptrCast(scaled_data.ptr);
        rgb_img.rowBytes = e.w * work_channels * 2;
        rgb_img.depth = 10;

        if (c.avifImageRGBToYUV(image, &rgb_img) != c.AVIF_RESULT_OK)
            return error.ConvertFailed;
    } else if (e.src.hbd and output_depth == 8) {
        const pixels = e.w * e.h;
        const scaled_data = try allocator.alloc(u8, pixels * work_channels);
        defer allocator.free(scaled_data);

        const src_u16 = @as([*]const u16, @ptrCast(@alignCast(work_data.ptr)))[0 .. pixels * work_channels];
        for (0..pixels * work_channels) |i|
            scaled_data[i] = @intCast(src_u16[i] >> 8);

        rgb_img.pixels = @ptrCast(scaled_data.ptr);
        rgb_img.rowBytes = e.w * work_channels;
        rgb_img.depth = 8;

        if (c.avifImageRGBToYUV(image, &rgb_img) != c.AVIF_RESULT_OK)
            return error.ConvertFailed;
    } else { // !hbd, output depth = 8
        rgb_img.pixels = @ptrCast(@constCast(work_data.ptr));
        rgb_img.rowBytes = e.w * work_channels;
        rgb_img.depth = 8;

        if (c.avifImageRGBToYUV(image, &rgb_img) != c.AVIF_RESULT_OK)
            return error.ConvertFailed;
    }

    const avifenc = c.avifEncoderCreate();
    if (avifenc == null) return error.OutOfMemory;
    defer c.avifEncoderDestroy(avifenc);

    try e.o.copyToEncoder(@ptrCast(avifenc));

    avifenc.*.quality = @intCast(e.q);
    avifenc.*.qualityAlpha = @intCast(o.quality_alpha);

    if (e.src.xmp) |xmp| {
        const result = c.avifImageSetMetadataXMP(image, xmp.ptr, xmp.len);
        if (result != c.AVIF_RESULT_OK)
            return error.SetXmpFailed;
    }

    var avif_output = c.avifRWData{ .data = null, .size = 0 };
    if (c.avifEncoderAddImage(avifenc, image, 1, c.AVIF_ADD_IMAGE_FLAG_SINGLE) != c.AVIF_RESULT_OK)
        return error.AddImageFailed;
    if (c.avifEncoderFinish(avifenc, &avif_output) != c.AVIF_RESULT_OK)
        return error.FinishFailed;
    defer c.avifRWDataFree(&avif_output);

    try output.appendSlice(allocator, @as([*]const u8, @ptrCast(avif_output.data))[0..avif_output.size]);
}

pub fn decodeAvifToRgb(allocator: std.mem.Allocator, avif_data: []const u8) ![]u8 {
    var result = try decodeAvifCommon(avif_data, true);
    defer c.avifRGBImageFreePixels(@ptrCast(&result.rgb));
    defer c.avifDecoderDestroy(result.decoder);

    const img = result.decoder.*.image;
    const width: usize = @intCast(img.*.width);
    const height: usize = @intCast(img.*.height);

    // return 8-bit RGB (no alpha) for fssimu2
    const pixels = width * height;
    const rgb_out = try allocator.alloc(u8, pixels * 3);
    errdefer allocator.free(rgb_out);

    const src_channels: usize = if (result.rgb.format == c.AVIF_RGB_FORMAT_RGBA) 4 else 3;

    for (0..height) |y| {
        const src_row = result.rgb.pixels + y * result.rgb.rowBytes;
        for (0..width) |x| {
            const src_idx = x * src_channels;
            const dst_idx = (y * width + x) * 3;
            rgb_out[dst_idx + 0] = src_row[src_idx + 0];
            rgb_out[dst_idx + 1] = src_row[src_idx + 1];
            rgb_out[dst_idx + 2] = src_row[src_idx + 2];
        }
    }

    return rgb_out;
}

pub fn encodeAvifToFile(e: *EncCtx, io_ctx: std.Io, allocator: std.mem.Allocator, output_path: []const u8) !void {
    var avif_data = try std.ArrayListAligned(u8, null).initCapacity(allocator, 0);
    defer avif_data.deinit(allocator);
    try encodeAvifToBuffer(e, allocator, &avif_data);

    const file = try std.Io.Dir.cwd().createFile(io_ctx, output_path, .{});
    defer file.close(io_ctx);
    var write_buffer: [8192]u8 = undefined;
    var writer = file.writerStreaming(io_ctx, &write_buffer);
    try writer.interface.writeAll(avif_data.items);
    try writer.interface.flush();
    e.buf.size = avif_data.items.len;
}
