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
        // 1. Check if the field already exists
        if (self.fields.contains(field_name)) {
            // If it exists, remove it.
            // This triggers the SIMD relocation to close the gap.
            self.removeField(field_name);
        }

        // 2. Prepare the new data
        const byteTransform = std.mem.toBytes(value);
        const byteLen: usize = byteTransform.len;
        const byteOffset: usize = self.memory.items.len;
        const valTypeID = @typeName(@TypeOf(value));

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
    defer _ = gpa.deinit();

    // 1. Initialize the Core
    var myCore = try DynamicCore.init("Voltex_Engine", allocator);
    defer myCore.deinit(allocator);

    // 2. Define the State Function Type
    // Returns the name of the next field to execute
    const StateFn = *const fn (core: *DynamicCore, alloc: std.mem.Allocator) []const u8;

    // 3. Register our Logic (Functions) and Data into the same buffer
    try myCore.setField("init", @as(StateFn, initializeState), allocator);
    try myCore.setField("work", @as(StateFn, workState), allocator);
    try myCore.setField("exit", @as(StateFn, exitState), allocator);

    // Initial Data
    try myCore.setField("counter", @as(i32, 0), allocator);

    // 4. The Stackless Trampoline Loop
    var current_state_key: []const u8 = "init";

    std.debug.print("--- Starting Voltex FSM ---\n", .{});

    while (!std.mem.eql(u8, current_state_key, "end")) {
        // Fetch the function pointer from the core
        const func = try myCore.getField(current_state_key, StateFn);

        // Execute and get the next state key
        const next_key = func(&myCore, allocator);

        std.debug.print("State Transition: {s} -> {s} (Buffer Len: {d})\n", .{ current_state_key, next_key, myCore.memory.items.len });

        current_state_key = next_key;
    }
}

// --- State Logic Functions ---

fn initializeState(core: *DynamicCore, alloc: std.mem.Allocator) []const u8 {
    _ = alloc;
    _ = core;
    std.debug.print("[INIT] Setting up resources...\n", .{});
    return "work";
}

fn workState(core: *DynamicCore, alloc: std.mem.Allocator) []const u8 {
    // Get counter, increment it, and set it back
    // This triggers the SIMD removeField/setField relocation internally!
    var count = core.getField("counter", i32) catch 0;
    count += 1;

    std.debug.print("[WORK] Iteration {d}...\n", .{count});
    core.setField("counter", count, alloc) catch unreachable;

    return if (count < 3) "work" else "exit";
}

fn exitState(core: *DynamicCore, alloc: std.mem.Allocator) []const u8 {
    _ = alloc;
    _ = core;
    std.debug.print("[EXIT] Shutting down...\n", .{});
    return "end";
}
