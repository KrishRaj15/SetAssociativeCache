# Parameterizable Set-Associative Cache

A synthesizable Verilog implementation of an N-way set-associative cache controller paired with a 64 KB synchronous main memory model.

---

## Overview

* **Associativity:** Configurable **2-way** or **4-way** set-associative architecture (default: 4-way, 16 sets, 8-byte lines $\rightarrow$ 512-byte cache).
* **Replacement Policy:** Counter-based **Least Recently Used (LRU)** eviction tracking per set.
* **Write Policy:** **Write-Through, No-Write-Allocate**
* *Write Hit:* Updates both cache line and main memory, then updates LRU status.
* *Write Miss:* Writes directly through to main memory without allocating a cache line.


* **Miss Handling:** On a read miss, an integrated multi-cycle FSM bursts the full 8-byte block from main memory into the selected victim way before returning data.

---

## Address Breakdown (16-bit)

```text
 15                 7 6           3 2          0
+--------------------+-------------+------------+
|     Tag (9 bits)   | Set (4 bits)| Byte Offset|
+--------------------+-------------+------------+

```

---

## FSM Workflow

1. **IDLE:** Waits for CPU read or write request.
2. **COMPARE:** Performs parallel tag and valid checks across ways; asserts `hit` or `miss`.
3. **READ_MISS_FETCH / WAIT:** Sequentially fetches the 8-byte block from main memory upon a read miss.
4. **UPDATE_CACHE:** Writes fetched data to the LRU victim line, updates valid/tag arrays, and sets MRU priority.
5. **WRITE_THROUGH:** Directly updates main memory (and cache line if hit).

---

## Quick Simulation

Compile and run using Icarus Verilog:

```bash
iverilog -o cache_sim main_memory.v set_associative_cache.v tb_cache.v
vvp cache_sim

```
