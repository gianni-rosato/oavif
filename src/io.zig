const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("spng.h");
    @cInclude("jpeglib.h");
    @cInclude("webp/decode.h");
    @cInclude("webp/mux.h");
    @cInclude("avif/avif.h");
    @cInclude("libheif/heif.h");
});

const EncCtx = @import("main.zig").EncCtx;
const print = std.debug.print;

pub fn printVersion(version: []const u8) void {
    const jpeg_version = c.LIBJPEG_TURBO_VERSION_NUMBER;
    const jpeg_major: comptime_int = jpeg_version / 1_000_000;
    const jpeg_minor: comptime_int = (jpeg_version / 1_000) % 1_000;
    const jpeg_patch: comptime_int = jpeg_version % 1_000;
    const jpeg_simd: bool = c.WITH_SIMD != 0;

    const webp_version = c.WebPGetDecoderVersion();
    const webp_major = webp_version >> 16;
    const webp_minor = (webp_version >> 8) & 0xFF;
    const webp_patch = webp_version & 0xFF;

    const avif_major: comptime_int = c.AVIF_VERSION_MAJOR;
    const avif_minor: comptime_int = c.AVIF_VERSION_MINOR;
    const avif_patch: comptime_int = c.AVIF_VERSION_PATCH;

    const heif_version = c.heif_get_version_number();
    const heif_major = heif_version >> 24;
    const heif_minor = (heif_version >> 16) & 0xFF;
    const heif_patch = (heif_version >> 8) & 0xFF;

    print("oavif {s}\n", .{version});
    print("libjpeg-turbo {d}.{d}.{d} ", .{ jpeg_major, jpeg_minor, jpeg_patch });
    print("[simd: {}]\n", .{jpeg_simd});
    print("libwebp {d}.{d}.{d}\n", .{ webp_major, webp_minor, webp_patch });
    print("libavif {d}.{d}.{d} (", .{ avif_major, avif_minor, avif_patch });

    var ver_buf: [256]u8 = undefined;
    c.avifCodecVersions(&ver_buf);
    const ver_str = std.mem.span(@as([*:0]u8, @ptrCast(&ver_buf)));
    print("{s})\n", .{ver_str});
    print("libheif {d}.{d}.{d}\n", .{ heif_major, heif_minor, heif_patch });
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

fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    const suffix = path[path.len - ext.len ..];
    return std.ascii.eqlIgnoreCase(suffix, ext);
}

fn detectImageFormat(data: []const u8, path: []const u8) !enum { jpeg, png, pam, webp, avif, heif, unknown } {
    if (data.len < 12) return error.InsufficientData;

    if (std.mem.eql(u8, data[0..3], "\xFF\xD8\xFF"))
        return .jpeg;
    if (std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1A\n"))
        return .png;
    if (std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP"))
        return .webp;
    if (std.mem.eql(u8, data[0..2], "P7"))
        return .pam;
    if (std.mem.eql(u8, data[4..8], "ftyp")) {
        if (std.mem.eql(u8, data[8..12], "avif"))
            return .avif;
        const brand = data[8..12];
        if (std.mem.eql(u8, brand, "heic") or
            std.mem.eql(u8, brand, "heix") or
            std.mem.eql(u8, brand, "heif") or
            std.mem.eql(u8, brand, "mif1") or
            std.mem.eql(u8, brand, "msf1"))
        {
            return .heif;
        }
    }

    if (hasExtension(path, ".jpg") or hasExtension(path, ".jpeg"))
        return .jpeg
    else if (hasExtension(path, ".png"))
        return .png
    else if (hasExtension(path, ".pam"))
        return .pam
    else if (hasExtension(path, ".webp"))
        return .webp
    else if (hasExtension(path, ".avif"))
        return .avif
    else if (hasExtension(path, ".heif") or hasExtension(path, ".heic"))
        return .heif;

    return .unknown;
}

pub fn loadImage(allocator: std.mem.Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var header: [12]u8 = undefined;
    const bytes_read = try file.readAll(&header);
    const format = try detectImageFormat(header[0..bytes_read], path);

    try file.seekTo(0);

    return switch (format) {
        .jpeg => loadJPEG(allocator, path),
        .png => loadPNG(allocator, path),
        .pam => loadPAM(allocator, path),
        .webp => loadWebP(allocator, path),
        .avif => loadAVIF(allocator, path),
        .heif => loadHEIF(allocator, path),
        .unknown => error.UnsupportedImageFormat,
    };
}

pub fn loadJPEG(allocator: std.mem.Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});

    const file_ptr = c.fdopen(file.handle, "rb");
    if (file_ptr == null) {
        file.close();
        return error.FailedToOpenFile;
    }
    defer _ = c.fclose(file_ptr);

    var cinfo: c.jpeg_decompress_struct = undefined;
    var jerr: c.jpeg_error_mgr = undefined;

    cinfo.err = c.jpeg_std_error(&jerr);
    c.jpeg_create_decompress(&cinfo);
    defer c.jpeg_destroy_decompress(&cinfo);

    c.jpeg_stdio_src(&cinfo, file_ptr);
    c.jpeg_save_markers(&cinfo, c.JPEG_APP0 + 1, 0xFFFF); // APP1 for EXIF and XMP
    c.jpeg_save_markers(&cinfo, c.JPEG_APP0 + 2, 0xFFFF); // APP2 for ICC

    if (c.jpeg_read_header(&cinfo, c.TRUE) != c.JPEG_HEADER_OK)
        return error.InvalidJPEGHeader;

    var icc_profile: ?[]u8 = null;
    var icc_data_ptr: [*c]u8 = null;
    var icc_data_len: c_uint = 0;
    if (c.jpeg_read_icc_profile(&cinfo, &icc_data_ptr, &icc_data_len) != 0)
        if (icc_data_len > 0 and icc_data_ptr != null) {
            icc_profile = try allocator.alloc(u8, icc_data_len);
            @memcpy(icc_profile.?, icc_data_ptr[0..icc_data_len]);
            c.free(icc_data_ptr);
        };

    var exif_data: ?[]u8 = null;
    var xmp_data: ?[]u8 = null;
    var marker = cinfo.marker_list;
    while (marker != null) : (marker = marker.*.next) {
        if (marker.*.marker == c.JPEG_APP0 + 1) {
            const marker_data = marker.*.data[0..marker.*.data_length];
            // EXIF: starts with "Exif\0\0"
            if (marker_data.len > 6 and std.mem.eql(u8, marker_data[0..6], "Exif\x00\x00")) {
                exif_data = try allocator.alloc(u8, marker.*.data_length - 6);
                @memcpy(exif_data.?, marker_data[6..]);
            }
            // XMP: starts with "http://ns.adobe.com/xap/1.0/\0"
            else if (marker_data.len > 29 and std.mem.startsWith(u8, marker_data, "http://ns.adobe.com/xap/1.0/\x00")) {
                xmp_data = try allocator.alloc(u8, marker.*.data_length - 29);
                @memcpy(xmp_data.?, marker_data[29..]);
            }
        }
    }

    if (cinfo.num_components == 1)
        cinfo.out_color_space = c.JCS_GRAYSCALE
    else
        cinfo.out_color_space = c.JCS_RGB;

    if (c.jpeg_start_decompress(&cinfo) != c.TRUE)
        return error.JPEGDecompressFailed;

    const width: usize = @intCast(cinfo.output_width);
    const height: usize = @intCast(cinfo.output_height);
    const channels: usize = @intCast(cinfo.output_components);

    const row_stride: usize = width * channels;
    const out_buf: []u8 = try allocator.alloc(u8, height * row_stride);
    errdefer {
        allocator.free(out_buf);
        if (icc_profile) |icc| allocator.free(icc);
        if (exif_data) |exif| allocator.free(exif);
        if (xmp_data) |xmp| allocator.free(xmp);
    }

    const row_buf = try allocator.alloc(u8, row_stride);
    defer allocator.free(row_buf);

    for (0..height) |y| {
        var row_pointers: [1][*c]u8 = .{row_buf.ptr};
        if (c.jpeg_read_scanlines(&cinfo, &row_pointers, 1) != 1) {
            if (icc_profile) |icc| allocator.free(icc);
            if (exif_data) |exif| allocator.free(exif);
            if (xmp_data) |xmp| allocator.free(xmp);
            return error.JPEGReadScanlinesFailed;
        }
        @memcpy(out_buf[y * row_stride .. (y + 1) * row_stride], row_buf);
    }

    if (c.jpeg_finish_decompress(&cinfo) != c.TRUE) {
        if (icc_profile) |icc| allocator.free(icc);
        if (exif_data) |exif| allocator.free(exif);
        if (xmp_data) |xmp| allocator.free(xmp);
        return error.JPEGFinishDecompressFailed;
    }

    return .{
        .width = width,
        .height = height,
        .channels = @intCast(channels),
        .hbd = false,
        .data = out_buf,
        .icc = icc_profile,
        .exif = exif_data,
        .xmp = xmp_data,
    };
}

pub fn loadPNG(allocator: std.mem.Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);

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

pub fn loadPAM(allocator: std.mem.Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const buf = try allocator.alloc(u8, file_size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    if (buf.len < 3 or !std.mem.startsWith(u8, buf, "P7")) return error.NotAPamFile;

    // Find header end. Prefer explicit ENDHDR marker; else look for double newline.
    const endhdr_explicit = std.mem.indexOf(u8, buf, "ENDHDR\n");
    var header_end_index: ?usize = null;
    if (endhdr_explicit) |i| {
        header_end_index = i + 7; // include terminator
    } else {
        // Look for first occurrence of "\n\n" (empty line). PAM spec mandates ENDHDR
        // but some generators may still use empty line.
        const empty_line = std.mem.indexOf(u8, buf, "\n\n");
        if (empty_line) |i| header_end_index = i + 2;
    }
    if (header_end_index == null) return error.HeaderNotFound;
    const header_end = header_end_index.?;

    const header = buf[0..header_end];

    var width: usize = 0;
    var height: usize = 0;
    var depth: usize = 0;
    var maxval: usize = 0;
    var tuple_type: []const u8 = "UNSPECIFIED";

    var line_it = std.mem.tokenizeAny(u8, header, "\r\n");
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') continue; // comment
        if (std.mem.startsWith(u8, line, "WIDTH")) {
            var it = std.mem.tokenizeAny(u8, line[5..], " \t");
            if (it.next()) |v| width = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "HEIGHT")) {
            var it = std.mem.tokenizeAny(u8, line[6..], " \t");
            if (it.next()) |v| height = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "DEPTH")) {
            var it = std.mem.tokenizeAny(u8, line[5..], " \t");
            if (it.next()) |v| depth = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "MAXVAL")) {
            var it = std.mem.tokenizeAny(u8, line[6..], " \t");
            if (it.next()) |v| maxval = try std.fmt.parseInt(usize, v, 10);
        } else if (std.mem.startsWith(u8, line, "TUPLTYPE")) {
            var it = std.mem.tokenizeAny(u8, line[8..], " \t");
            if (it.next()) |v| tuple_type = v;
        } else if (std.mem.eql(u8, line, "ENDHDR")) {
            break;
        }
    }

    if (width == 0 or height == 0 or depth == 0 or maxval == 0)
        return error.InvalidPamDimensions;
    if (maxval != 255) return error.UnsupportedPamMaxVal;
    if (depth != 1 and depth != 2 and depth != 3 and depth != 4)
        return error.UnsupportedPamDepth;

    var channels: u8 = @intCast(depth);
    if (std.ascii.eqlIgnoreCase(tuple_type, "GRAYSCALE")) {
        if (depth != 1) return error.PamTupleMismatch;
        channels = 1;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "GRAYSCALE_ALPHA")) {
        if (depth != 2) return error.PamTupleMismatch;
        channels = 2;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "RGB")) {
        if (depth != 3) return error.PamTupleMismatch;
        channels = 3;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "RGB_ALPHA")) {
        if (depth != 4) return error.PamTupleMismatch;
        channels = 4;
    } else if (std.ascii.eqlIgnoreCase(tuple_type, "BLACKANDWHITE")) {
        // binary (maxval should be 1) - not supporting
        return error.UnsupportedPamTuple;
    }

    const pixel_count = width * height;
    const data_size = pixel_count * channels;
    if (header_end + data_size > buf.len) return error.InsufficientDataInFile;

    const out = try allocator.alloc(u8, pixel_count * channels);
    errdefer allocator.free(out);
    @memcpy(out, buf[header_end .. header_end + data_size]);

    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .hbd = false,
        .data = out,
        .icc = null,
        .exif = null, // pam does not support metadata
        .xmp = null,
    };
}

pub fn loadWebP(allocator: std.mem.Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    var webp_data = c.WebPData{
        .bytes = buf.ptr,
        .size = buf.len,
    };

    var icc_profile: ?[]u8 = null;
    var exif_data: ?[]u8 = null;
    var xmp_data: ?[]u8 = null;

    const mux = c.WebPMuxCreate(&webp_data, 0);
    if (mux != null) {
        defer c.WebPMuxDelete(mux);

        var icc_chunk: c.WebPData = undefined;
        if (c.WebPMuxGetChunk(mux, "ICCP", &icc_chunk) == c.WEBP_MUX_OK) {
            if (icc_chunk.size > 0 and icc_chunk.bytes != null) {
                icc_profile = try allocator.alloc(u8, icc_chunk.size);
                @memcpy(icc_profile.?, icc_chunk.bytes[0..icc_chunk.size]);
            }
        }

        var exif_chunk: c.WebPData = undefined;
        if (c.WebPMuxGetChunk(mux, "EXIF", &exif_chunk) == c.WEBP_MUX_OK) {
            if (exif_chunk.size > 0 and exif_chunk.bytes != null) {
                exif_data = try allocator.alloc(u8, exif_chunk.size);
                @memcpy(exif_data.?, exif_chunk.bytes[0..exif_chunk.size]);
            }
        }

        var xmp_chunk: c.WebPData = undefined;
        if (c.WebPMuxGetChunk(mux, "XMP ", &xmp_chunk) == c.WEBP_MUX_OK) {
            if (xmp_chunk.size > 0 and xmp_chunk.bytes != null) {
                xmp_data = try allocator.alloc(u8, xmp_chunk.size);
                @memcpy(xmp_data.?, xmp_chunk.bytes[0..xmp_chunk.size]);
            }
        }
    }

    var features: c.WebPBitstreamFeatures = undefined;
    if (c.WebPGetFeatures(buf.ptr, buf.len, &features) != c.VP8_STATUS_OK)
        return error.WebPGetFeaturesFailed;

    const has_alpha = features.has_alpha != 0;
    const channels: u8 = if (has_alpha) 4 else 3;

    var width: c_int = 0;
    var height: c_int = 0;
    const data = if (has_alpha)
        c.WebPDecodeRGBA(buf.ptr, buf.len, &width, &height)
    else
        c.WebPDecodeRGB(buf.ptr, buf.len, &width, &height);
    if (data == null) return error.WebPDecodeFailed;
    defer c.WebPFree(data);

    const out_size = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * channels;
    const out_buf = try allocator.alloc(u8, out_size);
    errdefer {
        allocator.free(out_buf);
        if (icc_profile) |icc| allocator.free(icc);
        if (exif_data) |exif| allocator.free(exif);
        if (xmp_data) |xmp| allocator.free(xmp);
    }
    @memcpy(out_buf, @as([*]const u8, @ptrCast(data))[0..out_size]);

    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .channels = channels,
        .hbd = false,
        .data = out_buf,
        .icc = icc_profile,
        .exif = exif_data,
        .xmp = xmp_data,
    };
}

pub fn loadHEIF(allocator: std.mem.Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const size = try file.getEndPos();
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    const ctx = c.heif_context_alloc();
    if (ctx == null) return error.FailedCreateContext;
    defer c.heif_context_free(ctx);

    const err_read = c.heif_context_read_from_memory_without_copy(ctx, buf.ptr, buf.len, null);
    if (err_read.code != 0) return error.HeifReadFailed;

    var handle: ?*c.heif_image_handle = null;
    const err_handle = c.heif_context_get_primary_image_handle(ctx, &handle);
    if (err_handle.code != 0) return error.GetHandleFailed;
    defer c.heif_image_handle_release(handle);

    const width: usize = @intCast(c.heif_image_handle_get_width(handle));
    const height: usize = @intCast(c.heif_image_handle_get_height(handle));
    const has_alpha = c.heif_image_handle_has_alpha_channel(handle) != 0;

    const bit_depth: c_int = c.heif_image_handle_get_luma_bits_per_pixel(handle);
    const is_16bit = bit_depth > 8;

    var img: ?*c.heif_image = null;
    const chroma: c_uint = @intCast(if (is_16bit)
        (if (has_alpha) c.heif_chroma_interleaved_RRGGBBAA_BE else c.heif_chroma_interleaved_RRGGBB_BE)
    else
        (if (has_alpha) c.heif_chroma_interleaved_RGBA else c.heif_chroma_interleaved_RGB));

    const err_decode = c.heif_decode_image(handle, &img, c.heif_colorspace_RGB, chroma, null);
    if (err_decode.code != 0) return error.DecodeFailed;

    defer c.heif_image_release(img);

    const channels: u8 = if (has_alpha) 4 else 3;

    var icc_profile: ?[]u8 = null;
    const profile_type = c.heif_image_handle_get_color_profile_type(handle);
    if (profile_type == c.heif_color_profile_type_prof or profile_type == c.heif_color_profile_type_rICC) {
        const icc_size = c.heif_image_handle_get_raw_color_profile_size(handle);
        if (icc_size > 0) {
            icc_profile = try allocator.alloc(u8, icc_size);
            errdefer allocator.free(icc_profile.?);
            const err_icc = c.heif_image_handle_get_raw_color_profile(handle, icc_profile.?.ptr);
            if (err_icc.code != 0) {
                allocator.free(icc_profile.?);
                icc_profile = null;
            }
        }
    }

    var exif_data: ?[]u8 = null;
    var xmp_data: ?[]u8 = null;
    const num_metadata = c.heif_image_handle_get_number_of_metadata_blocks(handle, null);
    if (num_metadata > 0) {
        const meta_ids = try allocator.alloc(c.heif_item_id, @intCast(num_metadata));
        defer allocator.free(meta_ids);
        _ = c.heif_image_handle_get_list_of_metadata_block_IDs(handle, null, meta_ids.ptr, @intCast(num_metadata));

        for (meta_ids) |meta_id| {
            const meta_type_ptr = c.heif_image_handle_get_metadata_type(handle, meta_id);
            if (meta_type_ptr != null) {
                const meta_type = std.mem.span(meta_type_ptr);
                if (std.mem.eql(u8, meta_type, "Exif")) {
                    const exif_size = c.heif_image_handle_get_metadata_size(handle, meta_id);
                    if (exif_size > 0) {
                        exif_data = try allocator.alloc(u8, exif_size);
                        const err_exif = c.heif_image_handle_get_metadata(handle, meta_id, exif_data.?.ptr);
                        if (err_exif.code != 0) {
                            allocator.free(exif_data.?);
                            exif_data = null;
                        }
                    }
                } else if (std.mem.eql(u8, meta_type, "XMP")) {
                    const xmp_size = c.heif_image_handle_get_metadata_size(handle, meta_id);
                    if (xmp_size > 0) {
                        xmp_data = try allocator.alloc(u8, xmp_size);
                        const err_xmp = c.heif_image_handle_get_metadata(handle, meta_id, xmp_data.?.ptr);
                        if (err_xmp.code != 0) {
                            allocator.free(xmp_data.?);
                            xmp_data = null;
                        }
                    }
                } else if (std.mem.eql(u8, meta_type, "mime")) {
                    const content_type_ptr = c.heif_image_handle_get_metadata_content_type(handle, meta_id);
                    if (content_type_ptr != null) {
                        const content_type = std.mem.span(content_type_ptr);
                        if (std.mem.eql(u8, content_type, "application/rdf+xml")) {
                            const xmp_size = c.heif_image_handle_get_metadata_size(handle, meta_id);
                            if (xmp_size > 0) {
                                xmp_data = try allocator.alloc(u8, xmp_size);
                                const err_xmp = c.heif_image_handle_get_metadata(handle, meta_id, xmp_data.?.ptr);
                                if (err_xmp.code != 0) {
                                    allocator.free(xmp_data.?);
                                    xmp_data = null;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    var stride: c_int = 0;
    const plane_data = c.heif_image_get_plane_readonly(img, c.heif_channel_interleaved, &stride);

    const pixel_size: usize = if (is_16bit) 2 else 1;
    const row_size = width * channels * pixel_size;
    const out_size = height * row_size;

    const out_buf = try allocator.alloc(u8, out_size);
    errdefer {
        allocator.free(out_buf);
        if (icc_profile) |icc| allocator.free(icc);
        if (exif_data) |exif| allocator.free(exif);
        if (xmp_data) |xmp| allocator.free(xmp);
    }

    for (0..height) |y| {
        const src_offset = y * @as(usize, @intCast(stride));
        const dst_offset = y * row_size;
        @memcpy(out_buf[dst_offset..][0..row_size], plane_data[src_offset..][0..row_size]);
    }

    return .{
        .width = width,
        .height = height,
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

fn copyRgbPixels(allocator: std.mem.Allocator, rgb: c.avifRGBImage, width: usize, height: usize) ![]u8 {
    const channels: usize = if (rgb.format == c.AVIF_RGB_FORMAT_RGBA) 4 else 3;
    const bytes_per_sample: usize = if (rgb.depth > 8) 2 else 1;
    const out_buf = try allocator.alloc(u8, width * height * channels * bytes_per_sample);
    errdefer allocator.free(out_buf);

    for (0..height) |y| {
        const src_row = rgb.pixels + y * rgb.rowBytes;
        const dst_row = out_buf[y * width * channels * bytes_per_sample ..];
        @memcpy(dst_row[0 .. width * channels * bytes_per_sample], src_row[0 .. width * channels * bytes_per_sample]);
    }

    return out_buf;
}

pub fn loadAVIF(allocator: std.mem.Allocator, path: []const u8) !Image {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = try file.readAll(buf);

    var result = try decodeAvifCommon(buf, false);
    defer c.avifRGBImageFreePixels(@ptrCast(&result.rgb));
    defer c.avifDecoderDestroy(result.decoder);

    const img_ptr = result.decoder.*.image;
    const width: usize = @intCast(img_ptr.*.width);
    const height: usize = @intCast(img_ptr.*.height);
    const channels: u8 = if (result.rgb.format == c.AVIF_RGB_FORMAT_RGBA) 4 else 3;

    var icc_profile: ?[]u8 = null;
    if (img_ptr.*.icc.size > 0 and img_ptr.*.icc.data != null) {
        icc_profile = try allocator.alloc(u8, img_ptr.*.icc.size);
        @memcpy(icc_profile.?, img_ptr.*.icc.data[0..img_ptr.*.icc.size]);
    }

    var exif_data: ?[]u8 = null;
    if (img_ptr.*.exif.size > 0 and img_ptr.*.exif.data != null) {
        exif_data = try allocator.alloc(u8, img_ptr.*.exif.size);
        @memcpy(exif_data.?, img_ptr.*.exif.data[0..img_ptr.*.exif.size]);
    }

    var xmp_data: ?[]u8 = null;
    if (img_ptr.*.xmp.size > 0 and img_ptr.*.xmp.data != null) {
        xmp_data = try allocator.alloc(u8, img_ptr.*.xmp.size);
        @memcpy(xmp_data.?, img_ptr.*.xmp.data[0..img_ptr.*.xmp.size]);
    }

    const out_buf = try copyRgbPixels(allocator, result.rgb, width, height);
    errdefer allocator.free(out_buf);

    const hbd: bool = result.rgb.depth > 8;
    if (hbd) {
        const pixels = width * height * channels;
        const src_u16 = @as([*]u16, @ptrCast(@alignCast(out_buf.ptr)))[0..pixels];
        const shift: u4 = @intCast(16 - result.rgb.depth);
        for (src_u16) |*pixel|
            pixel.* = pixel.* << shift;
    }

    return .{
        .width = width,
        .height = height,
        .channels = channels,
        .hbd = hbd,
        .data = out_buf,
        .icc = icc_profile,
        .exif = exif_data,
        .xmp = xmp_data,
    };
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

pub fn encodeAvifToFile(e: *EncCtx, allocator: std.mem.Allocator, output_path: []const u8) !void {
    var avif_data = try std.ArrayListAligned(u8, null).initCapacity(allocator, 0);
    defer avif_data.deinit(allocator);
    try encodeAvifToBuffer(e, allocator, &avif_data);

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(avif_data.items);
    e.buf.size = avif_data.items.len;
}
