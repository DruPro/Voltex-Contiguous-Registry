# Voltex-Contiguous Registry (VCR)

A high-performance, data-oriented memory management architecture implemented in Zig. The Voltex-Contiguous Registry (VCR) utilizes SIMD-accelerated branchless mathematics to maintain a zero-fragmentation byte buffer for dynamic state machines and real-time systems.

---

## The Problem: The "Swiss Cheese" Heap

In traditional systems, frequent allocation and deallocation of properties lead to memory fragmentation. As "holes" appear in your heap, CPU cache efficiency plummets, and latency becomes unpredictable. Veterans call this "Pointer Chasing," and it is the silent killer of high-performance applications.

## The Solution: Deterministic Contiguity

VCR treats memory like a **tape**, not a warehouse. When a field is removed or updated, the system uses SIMD instructions to surgically shift all subsequent data to fill the gap. This ensures your data is always perfectly packed for the CPU prefetcher.

---

## Why Use Voltex?

### For the Performance Veteran

* **Branchless Relocation:** Recalculates offsets using the Iverson Bracket identity: . This eliminates branch mispredictions and pipeline stalls.
* **SIMD Throughput:** Updates up to 8 field offsets per CPU cycle using 256-bit vector registers.
* **Cache Locality:** Guarantees that related properties are physically adjacent in RAM, maximizing L1/L2 cache hits.

### For the Architecture Lead

* **Instant Serialization:** Since the entire state lives in one contiguous `u8` slice, saving or transmitting the state is a simple `write()` operation.
* **Hot-Swappable Logic:** Store function pointers (`StateFn`) alongside data. Swap program behavior at runtime without reallocating or stopping the engine.
* **Type Safety:** Built-in `typeID` validation ensures that raw byte access remains safe and predictable.

---

## Quick Start: The Stackless FSM

VCR is perfect for building high-speed state machines. Because the core is contiguous, your "Program Counter" is simply a key in the registry.

```zig
// Define your state logic
const StateFn = *const fn (core: *DynamicCore, alloc: Allocator) []const u8;

fn workState(core: *DynamicCore, alloc: Allocator) []const u8 {
    var count = core.getField("counter", i32) catch 0;
    count += 1;
    
    // Mutation triggers SIMD relocation automatically
    core.setField("counter", count, alloc) catch unreachable;

    return if (count < 100) "work" else "exit";
}

// The Trampoline Loop
var current_state: []const u8 = "init";
while (!std.mem.eql(u8, current_state, "end")) {
    const func = try myCore.getField(current_state, StateFn);
    current_state = func(&myCore, allocator);
}

```

---

## Technical Deep Dive: Relocation Math

VCR avoids `if` statements during memory shifts. By casting boolean comparisons to integers, we create a mathematical mask that the CPU can execute in a single pipeline.

```zig
// Concept: NewOffset = CurrentOffset - (HoleSize * Mask)
const mask = @intFromBool(offsets > start_v);
offsets -= (size_v * mask);

```

---

## Performance Considerations

VCR is designed for systems where **predictable latency** is more important than raw allocation speed. While every `setField` on an existing key incurs a relocation cost, the resulting memory density provides a significant speedup for all subsequent read operations and iterations.

---

## License

MIT License - Developed for the Voltex Engine.

---
