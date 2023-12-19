const std = @import("std");
const Allocator = std.mem.Allocator;
const phantom = @import("phantom");
const Format = @import("fmt.zig");
const Self = @This();

base: phantom.painting.image.Base,
fmt: *Format,
buffers: ?std.ArrayList(*phantom.painting.fb.Base),
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
        .buffers = null,
    };
    return self;
}

fn buffer(ctx: *anyopaque, i: usize) anyerror!*phantom.painting.fb.Base {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (self.buffers == null) self.buffers = try self.fmt.render();

    if (i > self.buffers.?.items.len) return error.OutOfBounds;
    return try self.buffers.?.items[i].dupe();
}

fn info(ctx: *anyopaque) phantom.painting.image.Base.Info {
    const self: *Self = @ptrCast(@alignCast(ctx));
    return self.fmt.imageInfo();
}

fn deinit(ctx: *anyopaque) void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (self.buffers) |buffers| {
        for (buffers.items) |fb| fb.deinit();
        buffers.deinit();
    }

    self.fmt.deinit();
    self.allocator.destroy(self);
}
