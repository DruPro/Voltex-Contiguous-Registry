# Voltex-Contiguous Registry (VCR)

The Voltex-Contiguous Registry (VCR) is a high-performance, data-oriented memory management architecture implemented in Zig. It utilizes SIMD-accelerated branchless mathematics to maintain a zero-fragmentation byte buffer for dynamic state machines and real-time systems.

By treating memory as a deterministic "tape" rather than a fragmented "warehouse," VCR eliminates pointer-chasing and maximizes CPU cache utilization.

---

## Technical Architecture: The "Tape" Model

In traditional systems, frequent allocation and deallocation of properties lead to memory fragmentation. As holes appear in the heap, CPU cache efficiency drops, and latency becomes unpredictable.

VCR solves this by enforcing **Deterministic Contiguity**. When a field is removed or its size is modified, VCR uses SIMD instructions to surgically shift all subsequent data to fill the gap. This ensures your data is always perfectly packed for the CPU prefetcher.

### Core Innovations

* **Branchless Relocation:** Offsets are recalculated using the Iverson Bracket identity: $$
\text{NewOffset} = \text{CurrentOffset} - \left( \text{HoleSize} \times [\text{CurrentOffset} > \text{HoleStart}] \right)
$$ . This eliminates branch mispredictions and pipeline stalls.
* **Structure of Arrays (SoA) Metadata:** Metadata (offsets, lengths, and name hashes) are stored in parallel contiguous arrays. This allows for **Linear SIMD Probing**, scanning up to 8 field hashes per CPU cycle using 256-bit vector registers.
* **Zero-Copy Serialization:** Because the entire state of an entity lives in a single contiguous `u8` slice, saving or transmitting the state is a raw memory "blit" ( complexity).

---

## Performance Benchmarks

Measured on 1,000 Actors with a total of 10,000,000 operations.

### Serialization & Search Efficiency

| Operation | Warehouse (Manual Crawl) | Voltex Tape (Bulk Blit) | Performance Gain |
| --- | --- | --- | --- |
| **Serialization (1k Actors)** | 346,000 ns | 29,400 ns | **11.7x Faster** |
| **Search (1M Lookups)** | 1,210,112,000 ns | 723,462,100 ns | **1.67x Faster** |

### VCR Chaos Mutation Results

Under high-frequency stress (randomly adding, removing, and updating fields), VCR maintains a predictable latency profile.

* **Total Operations:** 10,000,000
* **Elapsed Time:** 14,525,285,600 ns
* **Average Latency Per Action:** **1,452 ns** (includes SIMD relocation and metadata sync)

---

## Practical Application: The Living Entity

VCR allows for "metamorphic" data structures. You can change an entity's logic and data layout on the fly without breaking contiguity or reallocating the core object.

```zig
// VCR supports heterogeneous data side-by-side
try npc.setField("gold", @as(i32, 500), allocator);
try npc.setField("update_logic", npcMerchantBehavior, allocator);

// Instant Transformation: Merchant to Boss
npc.removeField("gold"); // SIMD shifts the tape to fill the gap
try npc.setField("hp", @as(i32, 5000), allocator);
try npc.setField("enrage_multi", @as(f32, 2.5), allocator);
try npc.setField("update_logic", npcBossBehavior, allocator);

// The entire Boss state is now a single, ready-to-save byte slice
const state_blob = npc.memory.items; 

```

---

## Technical Deep Dive: SIMD Relocation

VCR avoids `if` statements during memory shifts. By casting boolean comparisons to integers, we create a mathematical mask that the CPU executes in a single instruction pipeline.

```zig
// Logic: NewOffset = CurrentOffset - (HoleSize * Mask)
const mask = @intFromBool(offsets_vec > hole_start_vec);
offsets_vec -= (hole_size_vec * mask);

```

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
