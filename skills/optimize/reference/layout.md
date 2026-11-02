# Layout category: data layout, allocation, and redesign over caching

Applies to hot paths and large in-memory data, in any language. Look at what the program does to its data most often, then arrange memory to suit that. Skip cold code and small data: these changes add complexity, so they must earn it.

## Questions to ask of a hot path

- How can this be rewritten to better follow data-oriented design: what data does the loop actually touch, and how often?
- Can a hash table become a flat array? Can the keys be dense integer IDs?
- Can pointers become indices into an array?
- Can the most commonly used data be packed into the upper bits of the index?
- Should this be a structure of arrays rather than an array of structures?
- Can a heap-allocated list become a stack-allocated one with inline capacity?
- Can an array of bools become a bitset?
- Can these allocations share an arena instead of being cleaned up one by one?
- Is this cache hiding a slow design? Could a redesign make it unnecessary?

## Techniques

Flag a technique only when its "use when" fits the context.

| Technique | Use when | Avoid when |
|---|---|---|
| **Hash table → flat array** indexed by ID | Keys are dense or can be interned into small integers; lookups dominate | Keys are sparse, unbounded, or attacker-controlled, so the array could grow without limit |
| **Pointer → integer index** into an array (e.g. `u32`) | Many small linked objects; pointer size and chasing cost show up; data gets relocated or serialized | Items are freed often and no stale-index check exists. Add a generation counter, or don't convert |
| **Pack hot data into upper index bits** (e.g. a kind tag) | A loop mostly needs one small fact and would otherwise dereference to get it | The index range can't spare the bits. Assert on overflow and keep packing behind one accessor |
| **AoS → SoA** | Loops read a few fields across many items, or the code can vectorize | Most accesses use most fields of one item. Consider splitting hot and cold fields instead |
| **Array of bools → bitset** | Many flags, especially with bulk operations such as counting or intersecting | Threads write neighbouring flags without atomics, or there are only a handful of flags |
| **Arena** | Many allocations share a lifetime: a request, frame, parse, or compile phase | Items have mixed lifetimes, or need cleanup such as closing files or sockets |
| **Inline-capacity list on the stack** | Temporaries that are usually small; size inline capacity from the observed distribution | The compiler already keeps it on the stack (check escape analysis), the list escapes the function, its size is usually above capacity, or large buffers sit in deep recursion |

**Allocation order.** Start with an arena for data that shares a lifetime, which also removes per-item cleanup code. Use stack-allocated inline-capacity lists for temporaries, because an arena frees only in bulk and temporaries would otherwise pile up in it until the reset.

## Caching: test it, don't assume

Treat a cache as a question about the design: why is this slow enough to need one? Never add one as the first move, and don't delete one on principle.

**The cache test.** A cache passes when the first point holds and at least two of the others do. Count an unknown as not holding, and say it is unknown:

- The cost comes from something this code can't redesign away: a network call, a database, a metered API, or inherently expensive computation.
- Measurements show a useful hit rate and a real saving, or the origin's cost makes the case obvious.
- Staleness is acceptable and invalidation is correct, with keys covering every input that varies.
- Its memory is bounded.

**Redesign instead** when the cache sits in front of work this process fully controls, such as a lookup map rebuilt from data it already holds, or memoization covering for repeated work. Warning signs are invalidation bugs, a low hit rate, or a cache added to meet a target without finding out why the code was slow.

For a cache that fails the test, the finding's `fix:` is the redesign that removes the need for it. Remove the cache only as part of that redesign, with before/after numbers.

## Language equivalents

Verify an API exists in the project's version before recommending it. In managed languages the gains differ, so measure rather than assuming results carry over from systems code.

| Idea | Rust | C++ | Zig | Go | JS/TS | Python | JVM |
|---|---|---|---|---|---|---|---|
| Flat, unboxed data | `Vec<T>` | `std::vector<T>` | `std.ArrayList` | `[]T` of values | typed arrays | NumPy arrays | primitive arrays |
| SoA | one `Vec` per field | one `vector` per field | `std.MultiArrayList` | one slice per field | one typed array per field | NumPy columns, Polars | one primitive array per field |
| Bitset | `fixedbitset` | `std::bitset` | `std.DynamicBitSet` | `[]uint64` | `Uint32Array` | `int` masks, `numpy.packbits` | `java.util.BitSet` |
| Arena or reuse | `bumpalo` | `std::pmr::monotonic_buffer_resource` | `std.heap.ArenaAllocator` | reused slices, `sync.Pool` | reused buffers | rarely worthwhile | object pools, only if profiled |
| Inline capacity | `smallvec` | `absl::InlinedVector` | fixed buffer + `FixedBufferAllocator` | slice over a local array, if it doesn't escape | preallocated scratch buffer | rarely worthwhile | rarely worthwhile |

Measure with the project's benchmarks first, then a profiler such as `perf`, Instruments, `pprof`, `py-spy`, Chrome DevTools, or `async-profiler`. Compare allocation counts and peak memory as well as wall-clock time.
