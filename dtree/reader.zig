const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Self = @This();

pub const Node = union(enum) {
    begin: Begin,
    end: End,
    prop: Prop,

    pub const Begin = struct {
        depth: usize,
        name: []const u8,

        pub fn format(self: Begin, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = options;

            try writer.writeAll(@typeName(Begin));
            try writer.print("{{ .depth = {}, .name = \"{s}\" }}", .{
                self.depth,
                self.name,
            });
        }
    };

    pub const End = struct {
        depth: usize,
    };

    pub const Prop = struct {
        depth: usize,
        name: []const u8,
        value: []const u8,

        pub fn format(self: Prop, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = options;

            try writer.writeAll(@typeName(Prop));
            try writer.print("{{ .depth = {}, .name = \"{s}\", .value = {any} }}", .{
                self.depth,
                self.name,
                self.value,
            });
        }
    };

    pub fn name(self: Node) ?[]const u8 {
        return switch (self) {
            .begin => |b| b.name,
            .end => null,
            .prop => |p| p.name,
        };
    }

    pub fn depth(self: Node) usize {
        return switch (self) {
            .begin => |b| b.depth,
            .end => |e| e.depth,
            .prop => |p| p.depth,
        };
    }
};

pub const NodeIterator = struct {
    reader: *const Self,
    pos: usize = 0,
    depth: usize = 0,

    pub fn realPos(self: *const NodeIterator) usize {
        return self.pos + self.reader.hdr.off_dt_struct;
    }

    pub fn offset(self: *const NodeIterator) usize {
        return (self.pos + self.reader.hdr.off_dt_struct) - @sizeOf(types.Header);
    }

    pub fn alignTo(self: *NodeIterator, comptime T: type) void {
        self.pos += @sizeOf(T) - 1;
        self.pos &= ~@as(usize, @sizeOf(T) - 1);
    }

    pub fn readBuffer(self: *NodeIterator, buf: []u8) void {
        var i: usize = 0;
        while (i < buf.len) : (i += 1) {
            buf[i] = self.reader.buff[self.offset()];
            self.pos += 1;
        }
    }

    pub fn readBytes(self: *NodeIterator, len: usize) []const u8 {
        const pos = self.offset();
        const value = self.reader.buff[pos..][0..len];
        self.pos += len;
        return value;
    }

    pub fn readInt(self: *NodeIterator, comptime T: type) T {
        const len = @divExact(@typeInfo(T).Int.bits, 8);
        const pos = self.offset();
        const value = self.reader.buff[pos..][0..len];
        self.pos += len;
        return std.mem.readInt(T, value, .big);
    }

    pub fn readStruct(self: *NodeIterator, comptime T: type) T {
        var res: [1]T = undefined;
        self.readBuffer(std.mem.sliceAsBytes(res[0..]));
        if (builtin.cpu.arch.endian() != std.builtin.Endian.big) {
            std.mem.byteSwapAllFields(T, &res[0]);
        }
        return res[0];
    }

    pub fn token(self: *NodeIterator) std.meta.IntToEnumError!types.Token {
        return std.meta.intToEnum(types.Token, self.readInt(u32));
    }

    pub fn stringAt(self: *NodeIterator, off: usize) []const u8 {
        const pos = (self.reader.hdr.off_dt_strings + off) - @sizeOf(types.Header);
        const len = std.mem.len(@as([*c]const u8, @ptrCast(self.reader.buff[pos..])));
        return self.reader.buff[pos..(pos + len)];
    }

    pub fn string(self: *NodeIterator) []const u8 {
        const pos = self.offset();
        const len = std.mem.len(@as([*c]const u8, @ptrCast(self.reader.buff[pos..])));
        const str = self.reader.buff[pos..(pos + len)];
        self.pos += len + 1;
        return str;
    }

    pub fn next(self: *NodeIterator) !?Node {
        if (self.depth == 0 and self.pos > 0) return null;

        return switch (try self.token()) {
            .beginNode => blk: {
                self.depth += 1;
                const str = self.string();
                self.alignTo(u32);
                break :blk .{ .begin = .{
                    .name = str,
                    .depth = self.depth - 1,
                } };
            },
            .endNode => blk: {
                self.depth -= 1;
                break :blk .{ .end = .{ .depth = self.depth } };
            },
            .prop => blk: {
                const prop = self.readStruct(types.Prop);
                const name = self.stringAt(prop.name);
                const value = self.readBytes(prop.len);
                self.alignTo(u32);
                break :blk .{ .prop = .{
                    .depth = self.depth,
                    .name = name,
                    .value = value,
                } };
            },
            .nop => null,
            .end => error.InvalidToken,
        };
    }
};

allocator: ?Allocator,
hdr: types.Header,
buff: []const u8,

fn init(
    allocator: ?Allocator,
    reader: anytype,
    args: anytype,
    errors: anytype,
    initBufferFunc: fn (?Allocator, types.Header, @TypeOf(args)) (Allocator.Error || @TypeOf(reader).NoEofError || errors)![]const u8,
) !Self {
    const hdr = try reader.readStructBig(types.Header);
    if (hdr.magic != types.magic) return error.InvalidMagic;

    const buff = try initBufferFunc(allocator, hdr, args);
    errdefer {
        if (allocator) |alloc| alloc.free(buff);
    }

    const buffSize = hdr.totalsize - @sizeOf(types.Header);
    if (buff.len < buffSize) return error.Truncated;
    if (buff.len > buffSize) return error.OverRead;
    if (std.mem.readInt(u32, buff[(hdr.off_dt_struct - @sizeOf(types.Header))..][0..4], .big) != @intFromEnum(types.Token.beginNode)) return error.InvalidToken;

    return .{
        .allocator = allocator,
        .hdr = hdr,
        .buff = buff,
    };
}

pub fn initBuffer(buff: []const u8) !Self {
    var stream = std.io.fixedBufferStream(buff);
    return try init(null, stream.reader(), stream, error{}, (struct {
        fn func(
            _: ?Allocator,
            hdr: types.Header,
            argStream: std.io.FixedBufferStream([]const u8),
        ) (Allocator.Error || std.io.FixedBufferStream([]const u8).Reader.NoEofError)![]const u8 {
            return argStream.buffer[argStream.pos..hdr.totalsize];
        }
    }).func);
}

pub fn initReader(alloc: Allocator, reader: anytype) !Self {
    return try init(alloc, reader, reader, error{StreamTooLong}, (struct {
        fn func(
            argAlloc: ?Allocator,
            hdr: types.Header,
            argReader: @TypeOf(reader),
        ) (Allocator.Error || @TypeOf(reader).NoEofError || error{StreamTooLong})![]const u8 {
            return try argReader.readAllAlloc(argAlloc.?, hdr.totalsize - @sizeOf(types.Header));
        }
    }).func);
}

pub fn initFile(alloc: Allocator, file: std.fs.File) !Self {
    return try init(alloc, file.reader(), file, std.fs.File.ReadError || std.fs.File.MetadataError || error{FileTooBig}, (struct {
        fn func(
            argAlloc: ?Allocator,
            _: types.Header,
            argFile: std.fs.File,
        ) (Allocator.Error || std.fs.File.Reader.NoEofError || std.fs.File.ReadError || std.fs.File.MetadataError || error{FileTooBig})![]const u8 {
            const metadata = try argFile.metadata();
            return try argFile.readToEndAlloc(argAlloc.?, metadata.size() - @sizeOf(types.Header));
        }
    }).func);
}

pub fn deinit(self: *const Self) void {
    if (self.allocator) |alloc| alloc.free(self.buff);
}

pub fn nodeIterator(self: *const Self) NodeIterator {
    return .{ .reader = self };
}

pub fn writeDts(self: *const Self, writer: anytype) !void {
    var iter = self.nodeIterator();
    while (try iter.next()) |node| {
        for (0..(node.depth() * 2)) |_| try writer.writeByte(' ');

        switch (node) {
            .begin => |b| {
                try writer.writeAll(if (b.name.len == 0) "/" else b.name);
                try writer.writeAll(" {");
            },
            .end => {
                try writer.writeAll("}");
            },
            .prop => |p| {
                try writer.writeAll(p.name);
                try writer.writeAll(" = <");

                for (p.value, 0..) |c, i| {
                    try writer.print("0x{x}", .{c});
                    if (i + 1 < p.value.len) try writer.writeByte(' ');
                }

                try writer.writeByte('>');
            },
        }

        try writer.writeByte('\n');
    }
}

pub fn find(self: *const Self, path: []const []const u8) ![]const u8 {
    var iter = self.nodeIterator();
    while (try iter.next()) |node| {
        const depth = node.depth();
        if (depth >= path.len) return error.NotFound;

        const name = node.name() orelse continue;
        const pathItem = path[depth];

        if (!std.mem.eql(u8, name, pathItem)) continue;
        if ((depth + 1) == path.len) {
            if (node == .prop) return node.prop.value;
            return error.UnexpectedBeginOrEnd;
        }
    }
    return error.NotFound;
}
