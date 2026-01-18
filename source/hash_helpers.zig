const std = @import("std");

/// Wyhash is perfect for VCR because it's extremely fast
/// and fits perfectly into a CPU register.
pub const TypeID = u64;

pub fn gen_hash(input_data: []const u8, output: *TypeID) !void {
    // Wyhash is a 'seed-based' hash. We use 0 as the default seed.
    output.* = std.hash.Wyhash.hash(0, input_data);
}

pub fn print_hash(hash: TypeID) void {
    // Printing a u64 is much simpler than iterating a byte array
    std.debug.print("TypeID (Wyhash): 0x{x}\n", .{hash});
}
