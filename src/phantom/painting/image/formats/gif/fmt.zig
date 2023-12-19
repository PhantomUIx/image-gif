const std = @import("std");
const Allocator = std.mem.Allocator;
const phantom = @import("phantom");
const lzw = @import("lzw");
const vizops = @import("vizops");
const Types = @import("types.zig");
const Self = @This();

pub const Color = vizops.color.types.sRGB(u8);

pub const CommentExt = struct {
    value: []u8,

    pub fn deinit(self: CommentExt, alloc: Allocator) void {
        alloc.free(self.value);
    }
};

pub const AppExt = struct {
    appId: [8]u8,
    authCode: [3]u8,
    data: []u8,

    pub fn deinit(self: AppExt, alloc: Allocator) void {
        alloc.free(self.data);
    }
};

pub const SubImage = struct {
    lct: std.ArrayListUnmanaged(Color) = .{},
    imageDesc: Types.ImageDesc = .{},
    pixels: []u8 = &.{},

    pub fn deinit(self: *SubImage, alloc: Allocator) void {
        alloc.free(self.pixels);
        self.lct.deinit(alloc);
    }
};

pub const FrameData = struct {
    gfxCtrl: ?Types.GfxCtrlExt = null,
    subImages: std.ArrayListUnmanaged(SubImage) = .{},

    pub fn deinit(self: *FrameData, alloc: Allocator) void {
        for (self.subImages.items) |*subImg| subImg.deinit(alloc);
        self.subImages.deinit(alloc);
    }

    pub fn addSubImage(self: *FrameData, alloc: Allocator) !*SubImage {
        const subImage = try self.subImages.addOne(alloc);
        subImage.* = .{};
        return subImage;
    }
};

pub const Options = struct {
    version: Types.Version = .@"87a",
    width: u16,
    height: u16,
    depth: u3 = 7,
};

const ReadContext = struct {
    currFrameData: ?*FrameData = null,
    hasAnimAppExt: bool = false,
};

version: Types.Version,
hdr: Types.Header,
gct: std.ArrayListUnmanaged(Color) = .{},
frames: std.ArrayList(FrameData),
comments: std.ArrayListUnmanaged(CommentExt) = .{},
appInfos: std.ArrayListUnmanaged(AppExt) = .{},

pub fn init(alloc: Allocator, options: Options) !*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .version = options.version,
        .hdr = .{
            .magic = .{ 'G', 'I', 'F' },
            .version = @tagName(options.version)[0..3].*,
            .width = options.width,
            .height = options.height,
            .flags = .{
                .colorDepth = options.depth,
            },
        },
        .frames = std.ArrayList(FrameData).init(alloc),
    };
    return self;
}

pub fn read(alloc: Allocator, reader: anytype) !*Self {
    const hdr = try reader.readStruct(Types.Header);
    if (!std.mem.eql(u8, &hdr.magic, "GIF")) return error.InvalidMagic;

    const version = std.meta.stringToEnum(Types.Version, &hdr.version) orelse return error.InvalidVersion;

    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .version = version,
        .hdr = hdr,
        .frames = std.ArrayList(FrameData).init(alloc),
    };

    const gctSize = @as(usize, 1) << (@as(u6, @intCast(self.hdr.flags.gctSize)) + 1);
    try self.gct.ensureTotalCapacity(self.frames.allocator, gctSize);

    if (self.hdr.flags.hasGct) {
        var i: usize = 0;
        while (i < gctSize) : (i += 1) {
            const red = try reader.readInt(u8, .little);
            const green = try reader.readInt(u8, .little);
            const blue = try reader.readInt(u8, .little);

            self.gct.appendAssumeCapacity(.{
                .value = .{ red, green, blue, 255 },
            });
        }
    }

    var context: ReadContext = .{};
    try self.readData(&context, reader);
    return self;
}

fn readData(self: *Self, context: *ReadContext, reader: anytype) !void {
    var blk = try reader.readEnum(Types.DataBlockKind, .little);
    while (blk != .eof) {
        var isGfx = false;
        var extKind: ?Types.ExtKind = null;

        switch (blk) {
            .imageDesc => {
                isGfx = true;
            },
            .ext => {
                extKind = reader.readEnum(Types.ExtKind, .little) catch blk: {
                    var byte = try reader.readByte();
                    while (byte != Types.ExtBlockTerm) {
                        byte = try reader.readByte();
                    }
                    break :blk null;
                };

                if (extKind) |extKindValue| {
                    switch (extKindValue) {
                        .gfxCtrl, .plainText => {
                            isGfx = true;
                        },
                        else => {},
                    }
                } else {
                    blk = try reader.readEnum(Types.DataBlockKind, .little);
                }
            },
            .eof => return,
        }

        if (isGfx) {
            try self.readGfxBlock(context, blk, extKind, reader);
        } else {
            try self.readSpecialBlock(context, extKind.?, reader);
        }

        blk = try reader.readEnum(Types.DataBlockKind, .little);
    }
}

fn readGfxBlock(self: *Self, context: *ReadContext, blk: Types.DataBlockKind, extKind: ?Types.ExtKind, reader: anytype) !void {
    if (extKind) |extKindValue| {
        if (extKindValue == .gfxCtrl) {
            context.currFrameData = try self.addFrame();
            context.currFrameData.?.gfxCtrl = blk: {
                _ = try reader.readByte();

                var gfxCtrl: Types.GfxCtrlExt = undefined;
                gfxCtrl.flags = try reader.readStruct(Types.GfxCtrlExt.Flags);
                gfxCtrl.delay = try reader.readInt(u16, .little);

                if (gfxCtrl.flags.hasTransparency) {
                    gfxCtrl.transparentColor = try reader.readByte();
                } else {
                    _ = try reader.readByte();
                    gfxCtrl.transparentColor = 0;
                }

                _ = try reader.readByte();
                break :blk gfxCtrl;
            };

            const newBlk = try reader.readEnum(Types.DataBlockKind, .little);

            try self.readGfxRenderingBlock(context, newBlk, null, reader);
        } else if (extKindValue == .plainText) {
            try self.readGfxRenderingBlock(context, blk, extKind, reader);
        }
    } else {
        if (context.currFrameData == null) {
            context.currFrameData = try self.addFrame();
        } else if (context.hasAnimAppExt) {
            context.currFrameData = try self.addFrame();
        }

        try self.readGfxRenderingBlock(context, blk, extKind, reader);
    }
}

fn readGfxRenderingBlock(self: *Self, context: *ReadContext, blk: Types.DataBlockKind, extKind: ?Types.ExtKind, reader: anytype) !void {
    switch (blk) {
        .imageDesc => try self.readImgDesc(context, reader),
        .ext => {
            const kind = if (extKind) |value| value else try reader.readEnum(Types.ExtKind, .little);

            switch (kind) {
                .plainText => {
                    const blkSize = try reader.readByte();
                    try reader.skipBytes(blkSize, .{});

                    const subBlkSize = try reader.readByte();
                    try reader.skipBytes(subBlkSize + 1, .{});
                },
                else => return error.InvalidExtKind,
            }
        },
        .eof => return,
    }
}

fn readSpecialBlock(self: *Self, context: *ReadContext, extKind: Types.ExtKind, reader: anytype) !void {
    switch (extKind) {
        .comment => {
            const entry = try self.comments.addOne(self.frames.allocator);

            var list = try std.ArrayListUnmanaged(u8).initCapacity(self.frames.allocator, 256);
            defer list.deinit(self.frames.allocator);

            var blkSize = try reader.readByte();

            while (blkSize > 0) {
                var temp: [256]u8 = undefined;
                _ = try reader.read(temp[0..blkSize]);

                try list.appendSlice(self.frames.allocator, temp[0..blkSize]);
                blkSize = try reader.readByte();
            }

            entry.value = try self.frames.allocator.dupe(u8, list.items);
        },
        .appExt => {
            const appInfo = blk: {
                _ = try reader.readByte();

                var entry: AppExt = undefined;
                _ = try reader.read(&entry.appId);
                _ = try reader.read(&entry.authCode);

                var list = try std.ArrayListUnmanaged(u8).initCapacity(self.frames.allocator, 256);
                defer list.deinit(self.frames.allocator);

                var blkSize = try reader.readByte();

                while (blkSize > 0) {
                    var temp: [256]u8 = undefined;
                    _ = try reader.read(temp[0..blkSize]);

                    try list.appendSlice(self.frames.allocator, temp[0..blkSize]);
                    blkSize = try reader.readByte();
                }

                entry.data = try self.frames.allocator.dupe(u8, list.items);
                break :blk entry;
            };

            for (Types.animAppExts) |animExt| {
                if (std.mem.eql(u8, &appInfo.appId, animExt[0])) {
                    if (std.mem.eql(u8, &appInfo.authCode, animExt[1])) {
                        context.hasAnimAppExt = true;
                        break;
                    }
                }
            }

            try self.appInfos.append(self.frames.allocator, appInfo);
        },
        else => return error.InvalidExtKind,
    }
}

fn readImgDesc(self: *Self, context: *ReadContext, reader: anytype) !void {
    if (context.currFrameData) |currFrameData| {
        const subImg = try currFrameData.addSubImage(self.frames.allocator);
        subImg.imageDesc = try reader.readStruct(Types.ImageDesc);

        if (subImg.imageDesc.width == 0 or subImg.imageDesc.height == 0) return;

        const lctSize = @as(usize, 1) << (@as(u6, @intCast(subImg.imageDesc.flags.lctSize)) + 1);
        try subImg.lct.ensureTotalCapacity(self.frames.allocator, lctSize);

        if (subImg.imageDesc.flags.hasLct) {
            var i: usize = 0;
            while (i < lctSize) : (i += 1) {
                const red = try reader.readInt(u8, .little);
                const green = try reader.readInt(u8, .little);
                const blue = try reader.readInt(u8, .little);

                subImg.lct.appendAssumeCapacity(.{
                    .value = .{ red, green, blue, 255 },
                });
            }
        }

        const lzwMinCodeSize = try reader.readByte();
        if (lzwMinCodeSize == @intFromEnum(Types.DataBlockKind.eof)) return error.InvalidLzwCodeSize;

        subImg.pixels = try self.frames.allocator.alloc(u8, @as(usize, @intCast(subImg.imageDesc.height)) * @as(usize, @intCast(subImg.imageDesc.width)));
        var pixelsStream = std.io.fixedBufferStream(subImg.pixels);

        var decoder = try lzw.LittleDecoder.init(self.frames.allocator, lzwMinCodeSize);
        defer decoder.deinit();

        var blkSize = try reader.readByte();
        while (blkSize > 0) {
            var temp: [256]u8 = undefined;
            _ = try reader.read(temp[0..blkSize]);

            var tempStream = std.io.fixedBufferStream(&temp);

            const list = try decoder.decode(tempStream.reader());
            defer list.deinit();
            _ = try pixelsStream.write(list.items);

            blkSize = try reader.readByte();
        }
    }
}

pub fn render(self: *Self) !std.ArrayList(*phantom.painting.fb.Base) {
    var frames = try std.ArrayList(*phantom.painting.fb.Base).initCapacity(self.frames.allocator, @min(self.frames.items.len, 1));
    errdefer {
        for (frames.items) |f| f.deinit();
        frames.deinit();
    }

    if (self.frames.items.len == 0) {
        const fb = try self.createFrameBuffer();
        errdefer fb.deinit();

        try fillPalette(fb, self.gct.items, null);
        try fillWithBackgroundColor(fb, self.gct.items, self.hdr.backgroundColor);
        frames.appendAssumeCapacity(fb);
        return frames;
    }

    const canvas = try self.createFrameBuffer();
    defer canvas.deinit();

    const prevCanvas = try self.createFrameBuffer();
    defer prevCanvas.deinit();

    if (self.hdr.flags.hasGct) {
        try fillPalette(canvas, self.gct.items, null);
        try fillWithBackgroundColor(canvas, self.gct.items, self.hdr.backgroundColor);
        try canvas.blt(.to, prevCanvas, .{});
    }

    const _hasGfxCtrl = self.hasGfxCtrl();

    for (self.frames.items) |frame| {
        const currFrame = try self.createFrameBuffer();
        errdefer currFrame.deinit();

        var transparentColor: ?u8 = null;
        var disposeMethod = Types.GfxCtrlExt.Flags.DisposeMethod.none;

        if (frame.gfxCtrl) |gfxCtrl| {
            if (gfxCtrl.flags.hasTransparency) {
                transparentColor = gfxCtrl.transparentColor;
            }

            disposeMethod = gfxCtrl.flags.disposeMethod;
        }

        if (self.hdr.flags.hasGct) {
            try fillPalette(currFrame, self.gct.items, transparentColor);
        }

        for (frame.subImages.items) |*subImg| {
            const ctable = if (subImg.imageDesc.flags.hasLct) subImg.lct.items else self.gct.items;

            if (subImg.imageDesc.flags.hasLct) {
                try fillPalette(currFrame, ctable, transparentColor);
            }

            try self.renderSubImage(subImg, currFrame, ctable, transparentColor);
        }

        try canvas.blt(.to, currFrame, .{});

        if (!_hasGfxCtrl or (_hasGfxCtrl and frame.gfxCtrl != null)) {
            try frames.append(currFrame);
        } else {
            currFrame.deinit();
        }

        switch (disposeMethod) {
            .restorePrevious => try canvas.blt(.from, prevCanvas, .{}),
            .restoreBackground => {
                for (frame.subImages.items) |*subImg| {
                    const ctable = if (subImg.imageDesc.flags.hasLct) subImg.lct.items else self.gct.items;
                    try self.replaceWithBackground(subImg, canvas, ctable, transparentColor);
                }

                try canvas.blt(.to, prevCanvas, .{});
            },
            else => try canvas.blt(.to, prevCanvas, .{}),
        }
    }
    return frames;
}

pub fn deinit(self: *Self) void {
    for (self.frames.items) |*frame| frame.deinit(self.frames.allocator);
    for (self.comments.items) |*comment| comment.deinit(self.frames.allocator);
    for (self.appInfos.items) |*appInfo| appInfo.deinit(self.frames.allocator);

    self.gct.deinit(self.frames.allocator);
    self.comments.deinit(self.frames.allocator);
    self.appInfos.deinit(self.frames.allocator);
    self.frames.deinit();
}

pub fn addFrame(self: *Self) !*FrameData {
    const frame = try self.frames.addOne();
    frame.* = .{};
    return frame;
}

pub fn imageInfo(self: *Self) phantom.painting.image.Base.Info {
    const depth = @as(u8, @intCast(self.hdr.flags.colorDepth)) + 1;
    return .{
        .res = .{ .value = .{ @intCast(self.hdr.width), @intCast(self.hdr.height) } },
        .colorFormat = if (self.hasTransparency()) .{ .rgba = @splat(depth) } else .{ .rgb = @splat(depth) },
        .colorspace = .sRGB,
        .seqCount = self.frames.items.len,
    };
}

pub fn hasTransparency(self: *Self) bool {
    for (self.frames.items) |frame| {
        if (frame.gfxCtrl) |gfxCtrl| {
            if (gfxCtrl.flags.hasTransparency) return true;
        }
    }
    return false;
}

pub fn hasGfxCtrl(self: *Self) bool {
    for (self.frames.items) |frame| {
        if (frame.gfxCtrl) |_| {
            return true;
        }
    }
    return false;
}

fn createFrameBuffer(self: *Self) !*phantom.painting.fb.Base {
    const inf = self.imageInfo();
    return try phantom.painting.fb.AllocatedFrameBuffer.create(self.frames.allocator, .{
        .res = inf.res,
        .colorspace = inf.colorspace,
        .colorFormat = inf.colorFormat,
    });
}

fn fillPalette(fb: *phantom.painting.fb.Base, gct: []Color, transparentColor: ?u8) !void {
    _ = transparentColor;

    const size = @min(@reduce(.Mul, fb.info().res.value), gct.len);

    const buffer = try fb.allocator.alloc(u8, @divExact(fb.info().colorFormat.width(), 8));
    defer fb.allocator.free(buffer);

    var i: usize = 0;
    while (i < size) : (i += 1) {
        try gct[i].writeBuffer(fb.info().colorFormat, buffer);
        try fb.write(i, buffer);
    }
}

fn fillWithBackgroundColor(fb: *phantom.painting.fb.Base, gct: []Color, backgroundColor: u8) !void {
    const buffer = try fb.allocator.alloc(u8, @divExact(fb.info().colorFormat.width(), 8));
    defer fb.allocator.free(buffer);
    try gct[backgroundColor].writeBuffer(fb.info().colorFormat, buffer);

    var i: usize = 0;
    while (i < @reduce(.Mul, fb.info().res.value)) : (i += 1) {
        try fb.write(i, buffer);
    }
}

fn renderSubImage(self: *Self, subImg: *SubImage, fb: *phantom.painting.fb.Base, gct: []Color, transparentColor: ?u8) !void {
    if (subImg.imageDesc.flags.isInterlaced) {
        var sourceY: usize = 0;

        for (Types.interlacePasses) |pass| {
            var targetY = pass[0] + subImg.imageDesc.top;

            while (targetY < self.hdr.height) {
                const sourceStride = sourceY * subImg.imageDesc.width;
                const targetStride = targetY * self.hdr.width;

                for (0..subImg.imageDesc.width) |sourceX| {
                    const targetX = sourceX + subImg.imageDesc.left;

                    const sourceIndex = sourceStride + sourceX;
                    const targetIndex = targetStride + targetX;

                    try plotPixel(subImg, fb, gct, sourceIndex, targetIndex, transparentColor);
                }

                targetY += pass[1];
                sourceY += 1;
            }
        }
    } else {
        for (0..subImg.imageDesc.height) |sourceY| {
            const targetY = sourceY + subImg.imageDesc.top;

            const sourceStride = sourceY * subImg.imageDesc.width;
            const targetStride = targetY * self.hdr.width;

            for (0..subImg.imageDesc.width) |sourceX| {
                const targetX = sourceX + subImg.imageDesc.left;

                const sourceIndex = sourceStride + sourceX;
                const targetIndex = targetStride + targetX;

                try plotPixel(subImg, fb, gct, sourceIndex, targetIndex, transparentColor);
            }
        }
    }
}

fn replaceWithBackground(self: *Self, subImg: *SubImage, fb: *phantom.painting.fb.Base, gct: []Color, transparentColor: ?u8) !void {
    const backgroundColor = if (transparentColor) |v| v else self.hdr.backgroundColor;

    const buffer = try fb.allocator.alloc(u8, @divExact(fb.info().colorFormat.width(), 8));
    defer fb.allocator.free(buffer);
    try gct[backgroundColor].writeBuffer(fb.info().colorFormat, buffer);

    for (0..subImg.imageDesc.height) |sourceY| {
        const targetY = sourceY + subImg.imageDesc.top;

        const sourceStride = sourceY * subImg.imageDesc.width;
        const targetStride = targetY * self.hdr.width;

        for (0..subImg.imageDesc.width) |sourceX| {
            const targetX = sourceX + subImg.imageDesc.left;

            const sourceIndex = sourceStride + sourceX;
            const targetIndex = targetStride + targetX;

            if (sourceIndex >= subImg.pixels.len) continue;
            try fb.write(targetIndex, buffer);
        }
    }
}

fn plotPixel(subImg: *SubImage, fb: *phantom.painting.fb.Base, gct: []Color, sourceIndex: usize, targetIndex: usize, transparentColor: ?u8) !void {
    if (sourceIndex >= subImg.pixels.len) return;

    if (transparentColor) |t| {
        if (subImg.pixels[sourceIndex] == t) return;
    }

    const pixelIndex = subImg.pixels[sourceIndex];

    const buffer = try fb.allocator.alloc(u8, @divExact(fb.info().colorFormat.width(), 8));
    defer fb.allocator.free(buffer);

    if (pixelIndex < gct.len) {
        try gct[pixelIndex].writeBuffer(fb.info().colorFormat, buffer);
        try fb.write(targetIndex, buffer);
    }
}
