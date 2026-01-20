# Voltex-Contiguous Registry (VCR)

The Voltex-Contiguous Registry (VCR) is a high-performance, frequency aware memory management architecture. A lightweight, schema-flexible state container optimized for high-frequency mutation and cheap serialization, without hash map overhead.

> **Note on Project Maturity:** VCR is currently in its infancy (~400 lines). The architecture is bound to evolve as the development cycle iterates, but the core principles remain fixed on maximizing temporal locality and SIMD efficiency.

---

## Addressing Complexity: The Amortized  Path

A common misconception is that shifting data in a contiguous buffer always results in  overhead for every operation. VCR circumvents this through **Recency-Biased Compaction** and **Handle-Based Indexing**.

### 1. Recency-Biased Compaction

Due to the nature of the "Tape" model, VCR optimizes for how data actually changes in runtime:

* **Fixed-Size Stability:** Fields that do not change in byte-length (like `health` or `id`) never trigger a reorganization of the buffer.
* **The "Morphing" Tail:** When a field changes in size, it is appended to the end of the buffer. Only the fields physically located *behind* the change in the buffer require an offset update.
* **Complexity :** Where  is the subset of fields affected by a shift. By strategically placing frequently morphing fields at the end of the buffer,  approaches 1.

### 2. Handle-Based  Indexing

To avoid  searches for every field access, VCR utilizes **Handles**. A handle is a stored index that points directly to the data’s location on the tape.

```zig
const player = struct {
    health_handle: usize,
    core: DynamicCore
};

// 1. Initial set-up: The field is found once
try player.core.setField("health", @as(i32, 500), allocator);
player.health_handle = player.core.findFieldIndex("health"); 

// 2. Subsequent access: True O(1) via the handle
const current_health = player.core.getFieldByIndex(player.health_handle);

```

### 3. Temporal Locality and Workflow

By understanding the data's behavior, users can eliminate performance bottlenecks:

* **Static Fields:** Position these at the front of the buffer to ensure they are never shifted.
* **Dynamic Fields:** Position these at the tail. VCR is optimized to seek frequently shifting data at the buffer's end.

---

## Key Advantages: Serialization and Networking

Because VCR enforces **Deterministic Contiguity**, the entire state of an entity is a single, zero-fragmentation byte slice. This makes VCR uniquely suited for systems requiring "Pause and Resume" functionality or high-speed networking.

* **"Blit" Serialization:** Sending a player's state over a network becomes a simple memory copy (Memcpy).
* **Zero-Copy Restore:** On the receiving end, the buffer is restored, and handles are immediately valid for field access.

---

## Technical Benchmarks: VCR vs. The World

VCR is not a direct replacement for `StringArrayHashMap` or standard structs; it is a specialized tool for unique memory behaviors. However, when measured under high-frequency mutation (10,000,000 operations), VCR maintains a predictable latency profile.

| Operation | Warehouse (Manual Crawl) | VCR (Bulk Blit / Tape) |
| --- | --- | --- |
| **Serialization** | 212,100 ns | **23,800 ns** |
| **Search (1M Lookups)** | 869,927,500 ns (HashMap) | **471,030,300 ns (SIMD)** |

---

## SIMD Relocation Logic

VCR avoids standard `if/else` branching during memory shifts. By using the **Iverson Bracket** identity, the CPU recalculates offsets using branchless math, preventing pipeline stalls.

```zig
// SIMD implementation: Logic is applied to multiple fields simultaneously
const mask = @intFromBool(offsets_vec > hole_start_vec);
offsets_vec -= (hole_size_vec * mask);

```
