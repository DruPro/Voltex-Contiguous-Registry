pub fn gen_hash(input_data: []const u8, output: *[std.crypto.hash.Blake3.digest_length]u8) !void {
    std.crypto.hash.Blake3.hash(input_data, output, .{});
}

pub fn print_hash(hashbuff: [std.crypto.hash.Blake3.digest_length]u8) !void {
    std.debug.print("Hash :", .{});
    for (hashbuff) |char| {
        std.debug.print("{x}", .{char});
    }
}

const std = @import("std");
