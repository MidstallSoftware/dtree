const std = @import("std");

pub const magic: u32 = 0xd00dfeed;

pub const Header = packed struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,

    pub fn format(self: Header, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        try writer.writeAll(@typeName(Header));
        try writer.print("{{ .magic = 0x{x}, .totalsize = {}, .off_dt_struct = 0x{x}, .off_dt_strings = 0x{x}, .off_mem_rsvmap = 0x{x}, .version = {}, .last_comp_version = {}, .boot_cpuid_phys = {}, .size_dt_strings = {}, .size_dt_struct = {} }}", .{
            self.magic,
            std.fmt.fmtIntSizeDec(self.totalsize),
            self.off_dt_struct,
            self.off_dt_strings,
            self.off_mem_rsvmap,
            self.version,
            self.last_comp_version,
            self.boot_cpuid_phys,
            std.fmt.fmtIntSizeDec(self.size_dt_strings),
            std.fmt.fmtIntSizeDec(self.size_dt_struct),
        });
    }
};

pub const ReserveEntry = packed struct {
    address: u64,
    size: u64,
};

pub const Prop = packed struct {
    len: u32,
    name: u32,
};

pub const Token = enum(u32) {
    beginNode = 0x00000001,
    endNode = 0x00000002,
    prop = 0x00000003,
    nop = 0x00000004,
    end = 0x00000009,
};
