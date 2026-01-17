const std = @import("std");
const hashHelpers = @import("./hash_helpers.zig");
const builtin = @import("builtin");
const hashStringLen = std.crypto.hash.Blake3.digest_length;
const CoreID = [hashStringLen]u8;
const ByteTranform: type = []u8;
const FieldFetchErr = error{ invalidField, invalidType };

pub const DynamicCore = struct {
    CoreName: []const u8,
    memory: std.ArrayList(u8),
    fields: std.StringArrayHashMap(CoreField),

    pub fn init(name: []const u8, allocator: std.mem.Allocator) !DynamicCore {
        return DynamicCore{
            .CoreName = name,
            .memory = try std.ArrayList(u8).initCapacity(allocator, 0),
            .fields = std.StringArrayHashMap(CoreField).init(allocator),
        };
    }

    pub fn deinit(self: *DynamicCore, allocator: std.mem.Allocator) void {
        self.memory.deinit(allocator);
        self.fields.deinit();
    }

    /// Appends a new value to the end of the memory buffer.
    pub fn setField(self: *DynamicCore, field_name: []const u8, value: anytype, allocator: std.mem.Allocator) !void {
        // 1. Prepare the new data
        const byteTransform = std.mem.toBytes(value);
        const valTypeID = @typeName(@TypeOf(value));
        // 2. Check if the field already exists
        if (self.fields.getPtr(field_name)) |existing_field| {
            // --- THE GOLDEN PATH: In-Place Update ---
            if (existing_field.length == byteTransform.len) {
                const start = existing_field.offset;
                const end = start + existing_field.length;
                @memcpy(self.memory.items[start..end], &byteTransform);
                existing_field.typeID = valTypeID; // Update type if needed
                return;
            }

            // If size changed, we have to do the expensive move
            self.removeField(field_name);
        }

        const byteLen: usize = byteTransform.len;
        const byteOffset: usize = self.memory.items.len;

        // 3. Append to the end of the memory buffer
        try self.memory.appendSlice(allocator, &byteTransform);

        // 4. Register the new metadata
        const coreField: CoreField = CoreField{
            .offset = byteOffset,
            .length = byteLen,
            .typeID = valTypeID,
        };

        try self.fields.put(field_name, coreField);
    }

    /// Reconstructs the type from the byte buffer
    pub fn getField(
        self: *const DynamicCore,
        field_name: []const u8,
        comptime T: type, // Pass the type itself, not an instance
    ) !T {
        // 1. Get the field metadata (returns an Optional)
        // We use 'if' to check if the field exists and unwrap it in one go
        const field = self.fields.get(field_name) orelse {
            return error.invalidField;
        };
        if (!std.mem.eql(u8, field.typeID, @typeName(T))) {
            return error.invalidType;
        }
        const start = field.offset;
        const end = field.offset + field.length;
        const bytes = self.memory.items[start..end];
        return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
    }

    pub fn relocateOffsetsSIMD(self: *DynamicCore, hole_start: usize, hole_size: usize) void {
        const Vector = @Vector(8, usize);
        const start_v: Vector = @splat(hole_start);
        const size_v: Vector = @splat(hole_size);

        var i: usize = 0;
        const entries = self.fields.values(); // Get the slice of CoreField metadata

        // 1. Process offsets in chunks of 8
        while (i + 8 <= entries.len) : (i += 8) {
            // Load offsets into a vector
            var offsets: Vector = .{
                entries[i + 0].offset, entries[i + 1].offset,
                entries[i + 2].offset, entries[i + 3].offset,
                entries[i + 4].offset, entries[i + 5].offset,
                entries[i + 6].offset, entries[i + 7].offset,
            };

            // The Boolean Comparison: [CurrentOffset > HoleStart]
            // This creates a mask of 1s (true) and 0s (false)
            const mask = @intFromBool(offsets > start_v);

            // Apply the equation: NewOffset = CurrentOffset - (HoleSize * Mask)
            offsets -= (size_v * mask);

            // Store them back into the metadata
            inline for (0..8) |j| {
                entries[i + j].offset = offsets[j];
            }
        }

        // 2. Handle the remaining entries (the "tail") that didn't fit in a chunk of 8
        while (i < entries.len) : (i += 1) {
            const should_shift = @intFromBool(entries[i].offset > hole_start);
            entries[i].offset -= (hole_size * should_shift);
        }
    }
    /// Removes a field and shifts all memory/offsets to fill the gap
    pub fn removeField(self: *DynamicCore, field_name: []const u8) void {
        const meta = self.fields.get(field_name) orelse return;

        // 1. Physically shift the bytes in the buffer
        const bytes_after = self.memory.items[meta.offset + meta.length ..];
        std.mem.copyForwards(u8, self.memory.items[meta.offset..], bytes_after);
        self.memory.items.len -= meta.length;

        // 2. Mathematically relocate all other offsets using SIMD
        self.relocateOffsetsSIMD(meta.offset, meta.length);

        // 3. Remove the metadata entry
        _ = self.fields.swapRemove(field_name);
    }
};

const CoreField = struct {
    offset: usize,
    length: usize,
    typeID: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    // Use the GPA's check to ensure we cleaned up perfectly
    defer {
        const check = gpa.deinit();
        if (check == .leak) @panic("Memory Leak Detected!");
    }

    const actor_count: usize = 1_000;

    // --- Setup: Create 1,000 Actors ---
    var warehouse_actors = try allocator.alloc(std.StringHashMap(i32), actor_count);
    var voltex_actors = try allocator.alloc(DynamicCore, actor_count);

    // Clean up individual actors at the end
    defer {
        for (warehouse_actors) |*map| map.deinit();
        allocator.free(warehouse_actors);

        for (voltex_actors) |*core| core.deinit(allocator);
        allocator.free(voltex_actors);
    }

    for (0..actor_count) |i| {
        // Warehouse setup
        warehouse_actors[i] = std.StringHashMap(i32).init(allocator);
        try warehouse_actors[i].ensureTotalCapacity(3); // Fixes the 'grow' crash
        try warehouse_actors[i].put("hp", 100);
        try warehouse_actors[i].put("x", @intCast(i));
        try warehouse_actors[i].put("y", 20);

        // Voltex setup
        voltex_actors[i] = try DynamicCore.init("Actor", allocator);
        try voltex_actors[i].setField("hp", @as(i32, 100), allocator);
        try voltex_actors[i].setField("x", @as(i32, @intCast(i)), allocator);
        try voltex_actors[i].setField("y", @as(i32, 20), allocator);
    }

    // A giant buffer to simulate a "Save File" or "Network Packet"
    var world_buffer = std.ArrayListUnmanaged(u8){};
    try world_buffer.ensureTotalCapacity(allocator, 1024 * 1024);
    defer world_buffer.deinit(allocator);

    std.debug.print("--- Starting Serialization Benchmark ({d} Actors) ---\n", .{actor_count});

    // --- Benchmark 1: Warehouse Serialization ---
    {
        var timer = try std.time.Timer.start();
        for (warehouse_actors) |*map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                try world_buffer.appendSlice(allocator, entry.key_ptr.*);
                try world_buffer.appendSlice(allocator, &std.mem.toBytes(entry.value_ptr.*));
            }
        }
        const elapsed = timer.read();
        std.debug.print("Warehouse (Manual Crawl): {d:>12} ns\n", .{elapsed});
    }

    world_buffer.clearRetainingCapacity();

    // --- Benchmark 2: Voltex Tape Serialization ---
    {
        var timer = try std.time.Timer.start();
        for (voltex_actors) |*core| {
            // This is the "Zero-Effort" Bulk Blit
            try world_buffer.appendSlice(allocator, core.memory.items);
        }
        const elapsed = timer.read();
        std.debug.print("Voltex Tape (Bulk Blit):  {d:>12} ns\n", .{elapsed});
    }
}
