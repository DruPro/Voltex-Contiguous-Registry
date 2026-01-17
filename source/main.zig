const std = @import("std");
const hashHelpers = @import("./hash_helpers.zig");
const builtin = @import("builtin");
const hashStringLen = std.crypto.hash.Blake3.digest_length;
const CoreID = [hashStringLen]u8;
const TypeID = [hashStringLen]u8;
const FieldNameHash: type = u64;
const ByteTranform: type = []u8;
const FieldFetchErr = error{ invalidField, invalidType };

const CoreFieldMeta = struct {
    offset: std.ArrayList(usize),
    length: std.ArrayList(usize),
    typeID: std.ArrayList(TypeID),
    name_hashes: std.ArrayList(u64), // Used for SIMD matching
    names: std.ArrayList([]const u8), // Used for debugging/edge cases

    fn init(allocator: std.mem.Allocator) !CoreFieldMeta {
        return CoreFieldMeta{
            .offset = try std.ArrayList(usize).initCapacity(allocator, 0),
            .length = try std.ArrayList(usize).initCapacity(allocator, 0),
            .typeID = try std.ArrayList(TypeID).initCapacity(allocator, 0),
            .name_hashes = try std.ArrayList(u64).initCapacity(allocator, 0),
            .names = try std.ArrayList([]const u8).initCapacity(allocator, 0),
        };
    }

    fn deinit(self: *CoreFieldMeta, allocator: std.mem.Allocator) void {
        self.offset.deinit(allocator);
        self.length.deinit(allocator);
        self.typeID.deinit(allocator);
        self.name_hashes.deinit(allocator);
        self.names.deinit(allocator);
    }

    pub fn findFieldIndex(self: *const CoreFieldMeta, name: []const u8) ?usize {
        const target_hash: FieldNameHash = std.hash.Wyhash.hash(0, name); // Fast 64-bit hash
        const hashes = self.name_hashes.items;
        var i: usize = 0;

        // Process in chunks of 4 (using 256-bit SIMD for u64)
        const VecSize = 4;
        const Vec = @Vector(VecSize, u64);

        while (i + VecSize <= hashes.len) : (i += VecSize) {
            const chunk: Vec = hashes[i..][0..VecSize].*;
            const target_vec: Vec = @splat(target_hash);

            // Compare target against 4 hashes at once
            const match_mask = chunk == target_vec;

            // If any bit in the mask is true, we found it
            if (@reduce(.Or, match_mask)) {
                // Find which specific lane matched (0, 1, 2, or 3)
                inline for (0..VecSize) |lane| {
                    if (match_mask[lane]) return i + lane;
                }
            }
        }

        // Scalar tail for remaining items
        while (i < hashes.len) : (i += 1) {
            if (hashes[i] == target_hash) return i;
        }

        return null;
    }
};

const CoreField = struct {
    offset: usize,
    length: usize,
    typeID: []const u8,
};

pub const DynamicCore = struct {
    CoreName: []const u8,
    memory: std.ArrayList(u8),
    metaData: CoreFieldMeta,

    pub fn init(name: []const u8, allocator: std.mem.Allocator) !DynamicCore {
        return DynamicCore{
            .CoreName = name,
            .memory = try std.ArrayList(u8).initCapacity(allocator, 0),
            .metaData = try CoreFieldMeta.init(allocator),
        };
    }

    pub fn deinit(self: *DynamicCore, allocator: std.mem.Allocator) void {
        self.memory.deinit(allocator);
        self.metaData.deinit(allocator);
    }

    pub fn setField(self: *DynamicCore, field_name: []const u8, value: anytype, allocator: std.mem.Allocator) !void {
        // 1. Prepare the new data
        const byteTransform = std.mem.toBytes(value);
        var valTypeID: TypeID = undefined;
        try hashHelpers.gen_hash(@typeName(@TypeOf(value)), &valTypeID);

        // 2. Search for existing field index using SIMD-optimized scan
        if (self.metaData.findFieldIndex(field_name)) |idx| {
            // --- THE GOLDEN PATH: In-Place Update ---
            // We can only update in-place if the byte length hasn't changed
            if (self.metaData.length.items[idx] == byteTransform.len) {
                const start = self.metaData.offset.items[idx];
                const end = start + byteTransform.len;

                // Overwrite memory directly
                @memcpy(self.memory.items[start..end], &byteTransform);

                // Update type ID in the metadata array
                self.metaData.typeID.items[idx] = valTypeID;
                return;
            }

            // If size changed, we must remove it (which triggers SIMD shift)
            // and re-append at the end to maintain contiguity.
            self.removeField(field_name);
        }

        // 3. New Field or Size-Changed Field: Append to the end of the tape
        const byteLen: usize = byteTransform.len;
        const byteOffset: usize = self.memory.items.len;

        // Append raw data to the primary byte buffer
        try self.memory.appendSlice(allocator, &byteTransform);

        // 4. Update Metadata SoA (Parallel Push)
        // Generate the name hash for future SIMD searches
        const name_hash = std.hash.Wyhash.hash(0, field_name);

        try self.metaData.offset.append(allocator, byteOffset);
        try self.metaData.length.append(allocator, byteLen);
        try self.metaData.typeID.append(allocator, valTypeID);
        try self.metaData.name_hashes.append(allocator, name_hash);

        // We store the string name for debugging or scenarios where hashing isn't enough
        // Note: In a production VCR, you might want to duplicate the string to owned memory
        try self.metaData.names.append(allocator, field_name);
    }

    /// Reconstructs the type from the byte buffer
    pub fn getField(self: *const DynamicCore, field_name: []const u8, comptime T: type) !T {
        const idx = self.metaData.findFieldIndex(field_name) orelse return error.FieldNotFound;

        // 1. Verify Type (Safety First)
        var target_type_hash: TypeID = undefined;
        try hashHelpers.gen_hash(@typeName(T), &target_type_hash);

        if (!std.mem.eql(u8, &self.fields.typeIDs.items[idx], &target_type_hash)) {
            return error.TypeMismatch;
        }

        // 2. Direct Indexing (Fast!)
        const offset = self.fields.offsets.items[idx];
        const length = self.fields.lengths.items[idx];

        const bytes = self.memory.items[offset..][0..length];
        return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
    }

    pub fn relocateOffsetsSIMD(self: *DynamicCore, hole_start: usize, hole_size: usize) void {
        // With SoA, offsets is just a slice of usize. No more struct jumping!
        const offsets = self.metaData.offset.items;

        const VecSize = 8;
        const Vec = @Vector(VecSize, usize);
        const start_v: Vec = @splat(hole_start);
        const size_v: Vec = @splat(hole_size);

        var i: usize = 0;

        // 1. Process in blocks of 8
        while (i + VecSize <= offsets.len) : (i += VecSize) {
            // Load the block directly into a vector
            var v: Vec = offsets[i..][0..VecSize].*;

            // The Iverson Bracket Math:
            // NewOffset = OldOffset - (HoleSize * [OldOffset > HoleStart])
            const mask = @intFromBool(v > start_v);
            v -= (size_v * mask);

            // Write the block back to memory in one go
            offsets[i..][0..VecSize].* = v;
        }

        // 2. Handle the tail (scalar fallback)
        while (i < offsets.len) : (i += 1) {
            // We use the same branchless logic even in the tail for consistency
            const should_shift = @intFromBool(offsets[i] > hole_start);
            offsets[i] -= (hole_size * should_shift);
        }
    }

    /// Removes a field and shifts all memory/offsets to fill the gap
    pub fn removeField(self: *DynamicCore, field_name: []const u8) void {
        // 1. Find the index using our SIMD Search
        const idx = self.metaData.findFieldIndex(field_name) orelse return;

        // Capture the metadata before we start shifting things
        const hole_offset = self.metaData.offset.items[idx];
        const hole_length = self.metaData.length.items[idx];

        // 2. Physically shift the bytes in the memory tape
        // This fills the 'hole' in the raw byte buffer
        const bytes_after = self.memory.items[hole_offset + hole_length ..];
        std.mem.copyForwards(u8, self.memory.items[hole_offset..], bytes_after);
        self.memory.items.len -= hole_length;

        // 3. Mathematically relocate all offsets that pointed to data AFTER the hole
        // Note: We do this BEFORE the swapRemove so the indices are still stable
        self.relocateOffsetsSIMD(hole_offset, hole_length);

        // 4. Synchronized swapRemove
        // We remove the metadata at 'idx' by swapping the last element into its place.
        // This must be done for EVERY array in the SoA to keep them in sync.
        _ = self.metaData.offset.swapRemove(idx);
        _ = self.metaData.length.swapRemove(idx);
        _ = self.metaData.typeID.swapRemove(idx);
        _ = self.metaData.name_hashes.swapRemove(idx);
        _ = self.metaData.names.swapRemove(idx);
    }
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
    // --- Benchmark 3: Search Speed ---
    // HashMap vs. VCR SIMD-SoA
    {
        const iterations: usize = 10_000;

        // 1. Warehouse (HashMap) Search
        {
            var timer = try std.time.Timer.start();
            for (0..iterations) |_| {
                for (warehouse_actors) |*map| {
                    _ = map.get("hp");
                }
            }
            const elapsed = timer.read();
            std.debug.print("HashMap Search (1M Lookups): {d:>12} ns\n", .{elapsed});
        }

        // 2. Voltex SIMD-SoA Search
        {
            var timer = try std.time.Timer.start();
            for (0..iterations) |_| {
                for (voltex_actors) |*core| {
                    _ = core.metaData.findFieldIndex("hp");
                }
            }
            const elapsed = timer.read();
            std.debug.print("Voltex SIMD Search (1M Lookups): {d:>12} ns\n", .{elapsed});
        }
    }
    // --- Benchmark 4: The Chaos Stress Test (SoA Edition) ---
    // 10,000 frames of random mutations across 1,000 actors
    // --- Benchmark 4: The Chaos Stress Test ---
    {
        var prng = std.Random.DefaultPrng.init(42); // Note the capital 'R' and .Random
        const rand = prng.random();
        var timer = try std.time.Timer.start();

        for (0..10_000) |_| {
            for (voltex_actors) |*core| {
                const action = rand.uintLessThan(u8, 100);

                if (action < 20) {
                    // 20% Chance: Dynamic Removal
                    core.removeField("speed_boost");
                } else if (action < 50) {
                    // 30% Chance: Dynamic Insertion
                    const poison_val = rand.float(f32) * 10.0;
                    try core.setField("poison_dot", poison_val, allocator);
                } else {
                    // 50% Chance: Golden Path (In-place)
                    try core.setField("hp", @as(i32, 95), allocator);
                }
            }
        }

        const elapsed = timer.read();
        const total_ops = 10_000 * actor_count;
        std.debug.print("\n--- VCR Chaos Mutation Results ---\n", .{});
        std.debug.print("Total Operations: {d}\n", .{total_ops});
        std.debug.print("Elapsed Time:     {d:>12} ns\n", .{elapsed});
        std.debug.print("Avg Per Action:   {d:>12} ns\n", .{elapsed / total_ops});
    }
}
