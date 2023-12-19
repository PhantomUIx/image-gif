const std = @import("std");
const Allocator = std.mem.Allocator;
const phantom = @import("phantom");
const Format = @import("fmt.zig");
const Self = @This();

base: phantom.painting.image.Base,
fmt: *Format,
allocator: Allocator,

pub fn create(alloc: Allocator, fmt: *Format) Allocator.Error!*Self {
    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .base = .{
            .ptr = self,
            .vtable = &.{
                .buffer = buffer,
                .info = info,
                .deinit = deinit,
            },
        },
        .fmt = fmt,
        .allocator = alloc,
    };
    return self;
}

fn buffer(ctx: *anyopaque, i: usize) anyerror!*phantom.painting.fb.Base {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (i > self.fmt.images.items.len) return error.InvalidSeq;

    const img = &self.fmt.images.items[i];
    const inf = self.fmt.imageInfo();
    const colorTable = if (img.lct.items.len > 0) img.lct else self.fmt.colorTable;

    const fb = try phantom.painting.fb.AllocatedFrameBuffer.create(self.allocator, .{
        .res = inf.res,
        .colorspace = inf.colorspace,
        .colorFormat = inf.colorFormat,
    });
    errdefer fb.deinit();

    var ioff: usize = img.y * self.fmt.width + img.x;
    var y: usize = 0;
    while (y < img.height) : (y += 1) {
        var x: usize = 0;
        while (x < img.width) : (x += 1) {
            const index = img.buf[(img.y + y) * self.fmt.width + img.x + x];
            const color = &colorTable.items[index * 3];

            if (self.fmt.gce.transparency == 0 or index != self.fmt.gce.tindex) {
                try fb.write((ioff + x) * 3, &[_]u8{ color.r, color.g, color.b });
            }
        }

        ioff += self.fmt.width;
    }
    return fb;
}

fn info(ctx: *anyopaque) phantom.painting.image.Base.Info {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.fmt.imageInfo();
}

fn deinit(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.fmt.deinit();
    self.allocator.destroy(self);
}
