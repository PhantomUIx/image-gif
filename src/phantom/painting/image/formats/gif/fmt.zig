const std = @import("std");
const Allocator = std.mem.Allocator;
const phantom = @import("phantom");
const Self = @This();

pub const Color = extern struct { r: u8, g: u8, b: u8 };

pub const Gce = struct {
    delay: u16 = 0,
    tindex: u8 = 0,
    disposal: u8 = 0,
    input: u32 = 0,
    transparency: u32 = 0,
};

pub const Image = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    lct: std.ArrayList(Color),
    buf: []usize,

    pub fn deinit(self: Image) void {
        self.lct.deinit();
        self.lct.allocator.free(self.buf);
    }
};

const TableEntry = struct {
    len: usize,
    prefix: usize,
    suffix: usize,

    pub fn def(key: usize) TableEntry {
        return .{
            .len = 1,
            .prefix = 0xFFF,
            .suffix = key,
        };
    }
};

width: u16,
height: u16,
depth: u8,
backgroundColor: u8,
aspectRatio: u8,
loopCount: u16,
colorTable: std.ArrayList(Color),
images: std.ArrayList(Image),
gce: Gce,

fn discardSubblocks(reader: anytype) !void {
    while (true) {
        const size = try reader.readInt(u8, .little);
        if (size == 0) break;
        _ = try reader.skipBytes(size, .{});
    }
}

fn interlaceLineIndex(h: usize, y: usize) usize {
    var p = (h - 1) / 8 + 1;
    if (y < p) return y * 8;

    var y2 = y - p;
    p = (h - 5) / 8 + 1;
    if (y2 < p) return y2 * 8 + 4;

    y2 -= p;
    p = (h - 3) / 4 + 1;
    if (y2 < p) return y2 * 4 + 2;

    y2 -= p;
    return y2 * 2 + 1;
}

fn getKey(reader: anytype, keySize: usize, subLen: *u8, shift: *usize, byte: *u8) !usize {
    var rpad: usize = 0;
    var key: usize = 0;
    var bitsRead: usize = 0;
    var fragSize: usize = 0;

    while (bitsRead < keySize) : (bitsRead += fragSize) {
        rpad = @intCast((shift.* + bitsRead) % 8);
        if (rpad == 0) {
            if (subLen.* == 0) {
                subLen.* = try reader.readInt(u8, .little);
                if (subLen.* == 0) return 0x1000;
            }

            byte.* = try reader.readInt(u8, .little);
            subLen.* -= 1;
        }

        fragSize = @min(keySize - bitsRead, 8 - rpad);
        key |= @intCast((byte.* >> @as(u3, @intCast(rpad))) << @as(u3, @truncate(bitsRead)));
    }

    key &= @intCast((@as(usize, 1) << @as(u6, @truncate(keySize))) - 1);
    shift.* = (shift.* + keySize) % 8;
    return key;
}

pub fn fromInfo(alloc: Allocator, info: phantom.painting.image.Base.Info) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .width = @intCast(info.res.value[0]),
        .height = @intCast(info.res.value[1]),
        .depth = @intCast(info.colorFormat.channelSize()),
        .backgroundColor = 0,
        .aspectRatio = 0,
        .loopCount = 0,
        .colorTable = std.ArrayList(Color).init(alloc),
        .images = std.ArrayList(Image).init(alloc),
        .gce = .{},
    };
    return self;
}

pub fn read(alloc: Allocator, reader: anytype) !*Self {
    var sig: [3]u8 = undefined;
    _ = try reader.read(&sig);
    if (!std.mem.eql(u8, &sig, "GIF")) return error.InvalidMagic;

    var ver: [3]u8 = undefined;
    _ = try reader.read(&ver);
    if (!std.mem.eql(u8, &ver, "89a")) return error.InvalidMagic;

    const width = try reader.readInt(u16, .little);
    const height = try reader.readInt(u16, .little);

    const fdsz = try reader.readInt(u8, .little);

    if ((fdsz & 0x80) == 0) return error.MissingGct;

    const depth = ((fdsz >> 4) & 7) + 1;
    const gctsz = @as(usize, 1) << @as(u6, @intCast((fdsz & 0x7) + 1));

    const backgroundColor = try reader.readInt(u8, .little);
    const aspectRatio = try reader.readInt(u8, .little);

    const self = try alloc.create(Self);
    self.* = .{
        .width = width,
        .height = height,
        .depth = depth,
        .backgroundColor = backgroundColor,
        .aspectRatio = aspectRatio,
        .loopCount = 0,
        .colorTable = try std.ArrayList(Color).initCapacity(alloc, gctsz),
        .images = std.ArrayList(Image).init(alloc),
        .gce = undefined,
    };
    errdefer {
        for (self.images.items) |img| img.deinit();
        self.colorTable.deinit();
        self.images.deinit();
        alloc.destroy(self);
    }

    var i: usize = 0;
    while (i < gctsz) : (i += 1) {
        self.colorTable.appendAssumeCapacity(try reader.readStruct(Color));
    }

    while (true) {
        const sep = try reader.readInt(u8, .little);
        switch (sep) {
            '!' => {
                const label = try reader.readInt(u8, .little);
                switch (label) {
                    0x1 => {
                        _ = try reader.skipBytes(13, .{});
                        try discardSubblocks(reader);
                    },
                    0xF9 => {
                        _ = try reader.skipBytes(1, .{});

                        const rdit = try reader.readInt(u8, .little);
                        self.gce.disposal = (rdit >> 2) & 3;
                        self.gce.input = rdit & 2;
                        self.gce.transparency = rdit & 1;
                        self.gce.delay = try reader.readInt(u16, .little);
                        self.gce.tindex = try reader.readInt(u8, .little);

                        _ = try reader.skipBytes(1, .{});
                    },
                    0xFE => try discardSubblocks(reader),
                    0xFF => {
                        try reader.skipBytes(1, .{});

                        var appId: [8]u8 = undefined;
                        _ = try reader.read(&appId);

                        var authCode: [3]u8 = undefined;
                        _ = try reader.read(&authCode);

                        if (!std.mem.eql(u8, &appId, "NETSCAPE")) {
                            self.loopCount = try reader.readInt(u16, .little);
                            _ = try reader.skipBytes(1, .{});
                        } else {
                            try discardSubblocks(reader);
                        }
                    },
                    else => return error.InvalidExt,
                }
            },
            ';' => break,
            ',' => {
                var x = try reader.readInt(u16, .little);
                var y = try reader.readInt(u16, .little);

                if (x >= self.width or y >= self.height) return error.InvalidPosition;

                x = @min(x, self.width - x);
                y = @min(y, self.height - y);

                const fwidth = try reader.readInt(u16, .little);
                const fheight = try reader.readInt(u16, .little);

                const fisrz = try reader.readInt(u8, .little);
                const interlace = (fisrz & 0x40) != 0;

                var lct = std.ArrayList(Color).init(alloc);
                errdefer lct.deinit();

                if ((fisrz & 0x80) != 0) {
                    const lctsz = @as(usize, 1) << @as(u6, @intCast((fisrz & 0x7) + 1));
                    try lct.ensureTotalCapacity(lctsz);

                    i = 0;
                    while (i < lctsz) : (i += 1) {
                        lct.appendAssumeCapacity(try reader.readStruct(Color));
                    }
                }

                var keySize: usize = @intCast(try reader.readInt(u8, .little));
                if (keySize < 2 or keySize > 8) return error.InvalidKeySize;
                const initKeySize = keySize;

                const clear = @as(usize, 1) << @as(u6, @intCast(keySize));
                const stop = clear + 1;

                var tbl = std.AutoHashMap(usize, TableEntry).init(alloc);
                defer tbl.deinit();
                var tblEntryCount = (@as(usize, 1) << @as(u6, @intCast(keySize))) + 2;

                var subLen: u8 = 0;
                var shift: usize = 0;
                var byte: u8 = 0;
                var key = try getKey(reader, keySize, &subLen, &shift, &byte);
                var isTableFull = false;
                var strlen: usize = 0;
                var entry: TableEntry = undefined;
                var ret: u8 = 0;

                const size = @as(usize, @intCast(fwidth)) * @as(usize, @intCast(fheight));

                const buf = try alloc.alloc(usize, @as(usize, @intCast(self.width)) * @as(usize, @intCast(self.height)));
                errdefer alloc.free(buf);
                @memset(buf, self.backgroundColor);

                i = 0;
                while (i < size) {
                    if (key == clear) {
                        keySize = initKeySize;
                        tblEntryCount = (@as(usize, 1) << @as(u6, @intCast(keySize - 1))) + 2;
                        isTableFull = false;
                    } else if (!isTableFull) {
                        if (tbl.getPtr(tblEntryCount)) |eptr| {
                            eptr.* = .{
                                .len = strlen + 1,
                                .prefix = key,
                                .suffix = entry.suffix,
                            };
                        } else {
                            try tbl.put(tblEntryCount, .{
                                .len = strlen + 1,
                                .prefix = key,
                                .suffix = entry.suffix,
                            });
                        }

                        tblEntryCount += 1;
                        if ((tblEntryCount & (tblEntryCount - 1)) == 0) ret = 1;

                        if (tblEntryCount == 0x1000) {
                            ret = 0;
                            isTableFull = true;
                        }
                    }

                    key = try getKey(reader, keySize, &subLen, &shift, &byte);
                    if (key == clear) continue;
                    if (key == stop or key == 0x1000) break;
                    if (ret == 1) keySize += 1;

                    entry = tbl.get(key) orelse TableEntry.def(key);
                    strlen = entry.len;

                    var z: usize = 0;
                    while (z < strlen) : (z += 1) {
                        const p = i + entry.len - 1;
                        const px = p % fwidth;
                        var py = p / fwidth;

                        if (interlace) {
                            py = interlaceLineIndex(@intCast(fheight), py);
                        }

                        buf[(y + py) * self.width + x + px] = entry.suffix;

                        if (entry.prefix == 0xFFF) break;
                        entry = tbl.get(entry.prefix) orelse TableEntry.def(entry.prefix);
                    }

                    i += strlen;
                    if (key < tblEntryCount - 1 and !isTableFull) {
                        tbl.getPtr(tblEntryCount - 1).?.suffix = entry.suffix;
                    }
                }

                try self.images.append(.{
                    .x = x,
                    .y = y,
                    .width = fwidth,
                    .height = fheight,
                    .lct = lct,
                    .buf = buf,
                });
            },
            else => return error.InvalidSep,
        }
    }

    return self;
}

pub fn deinit(self: *Self) void {
    for (self.images.items) |img| img.deinit();
    self.colorTable.deinit();
    self.images.deinit();
    self.images.allocator.destroy(self);
}

pub fn imageInfo(self: *Self) phantom.painting.image.Base.Info {
    return .{
        .res = .{ .value = .{ @intCast(self.width), @intCast(self.height) } },
        .colorFormat = .{ .rgb = @splat(self.depth) },
        .colorspace = .sRGB,
        .seqCount = self.images.items.len,
    };
}
