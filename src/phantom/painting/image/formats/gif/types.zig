const builtin = @import("builtin");
const std = @import("std");

pub const Header = extern struct {
    magic: [3]u8 align(1),
    version: [3]u8 align(1),
    width: u16 align(1),
    height: u16 align(1),
    flags: Flags align(1) = .{},
    backgroundColor: u8 align(1) = 0,
    aspectRatio: u8 align(1) = 0,

    pub const Flags = packed struct {
        gctSize: u3 = 0,
        sorted: bool = false,
        colorDepth: u3 = 7,
        hasGct: bool = false,
    };
};

pub const ImageDesc = extern struct {
    left: u16 align(1) = 0,
    top: u16 align(1) = 0,
    width: u16 align(1) = 0,
    height: u16 align(1) = 0,
    flags: Flags align(1) = .{},

    pub const Flags = packed struct(u8) {
        lctSize: u3 = 0,
        reserved: u2 = 0,
        sort: bool = false,
        isInterlaced: bool = false,
        hasLct: bool = false,
    };
};

pub const GfxCtrlExt = extern struct {
    flags: Flags align(1),
    delay: u16 align(1),
    transparentColor: u8 align(1),

    pub const Flags = packed struct(u8) {
        hasTransparency: bool,
        userInput: bool,
        disposeMethod: DisposeMethod,
        reserved: u3 = 0,

        pub const DisposeMethod = enum(u3) {
            none = 0,
            dont = 1,
            restoreBackground = 2,
            restorePrevious = 3,
        };
    };
};

pub const DataBlockKind = enum(u8) {
    imageDesc = 0x2C,
    ext = 0x21,
    eof = 0x3B,
};

pub const ExtKind = enum(u8) {
    gfxCtrl = 0xF9,
    comment = 0xFE,
    plainText = 0x1,
    appExt = 0xFF,
};

pub const Version = enum {
    @"87a",
    @"89a",

    pub fn read(reader: anytype) !?Version {
        var temp: [3]u8 = undefined;
        _ = try reader.read(&temp);
        return std.meta.stringToEnum(Version, &temp);
    }
};

pub const KnownAppExt = struct { []const u8, []const u8 };
pub const animAppExts = [_]KnownAppExt{
    .{ "NETSCAPE", "2.0" },
    .{ "NETSCAPE", "1.0" },
};

pub const ExtBlockTerm = 0x00;

pub const interlacePasses = [_]struct { usize, usize }{
    .{ 0, 8 },
    .{ 4, 8 },
    .{ 2, 4 },
    .{ 1, 2 },
};
