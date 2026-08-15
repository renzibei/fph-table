// Counts what a fixed workload costs, deterministically.
//
// Wall-clock cannot gate anything on a shared CI runner, but the number of
// allocations a build performs, the bytes it asks for, its peak footprint and
// the number of times it copies or moves a key are exact integers that do not
// depend on how busy the machine is. They are the deterministic proxy for
// "this change made construction more expensive".
//
// `tests/ci/check-counters.sh` compares this output against
// tests/ci/baselines/counters-<platform>.txt as UPPER BOUNDS (<=), so any
// improvement passes without touching the baseline and only a regression
// fails. See docs/ci.md for how to move a bound on purpose.
//
// Determinism, and what it rests on:
//   * The library's parameter search seeds a std::mt19937_64 from a fixed seed
//     (default 0), so a successful build is reproducible.
//   * The dynamic table needs a RandomKeyGenerator to make its fill keys. The
//     default one seeds itself from std::random_device, which would make every
//     run different, so this probe passes an explicitly seeded generator that
//     uses its own splitmix64 rather than std::uniform_int_distribution --
//     std::uniform_int_distribution is not specified to produce the same values
//     across standard libraries.
//   * MEASURED, and the reason for the arena below: with an ordinary malloc,
//     100 consecutive runs of this program produced 100 DIFFERENT results, and
//     the spread reached 66% on one allocation counter. Running the same binary
//     under `setarch -R` (address space randomisation off) made all runs
//     identical. Something in the build path therefore depends on where the
//     allocator happens to place things. Serving every allocation from a bump
//     arena, so the layout is a pure function of the allocation sequence, makes
//     the whole program reproducible: 15/15 identical runs with ASLR still on.
//     This is a property of the library worth knowing about; here it is simply
//     removed, because a gate that is 66% noisy is not a gate.
//   * The library's own search does use std::uniform_int_distribution, so the
//     counts still differ between libstdc++ and libc++, and between compiler
//     versions. That is why the recorded baselines are tagged by toolchain and
//     why CI compares against the merge base built in the same job instead.
//
// Output format, one record per line:
//   <workload>.<counter> <value>

#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <new>
#include <utility>
#include <vector>

// ---------------------------------------------------------------- allocator --

namespace {

struct AllocStats {
    std::size_t allocations;
    std::size_t frees;
    std::size_t bytes;       // total requested over the whole workload
    std::size_t live_bytes;  // currently outstanding
    std::size_t peak_bytes;  // high-water mark of live_bytes
};

AllocStats g_alloc = {0, 0, 0, 0, 0};
bool g_counting = false;

// Every block carries a header so that operator delete knows the payload size
// even when the sized-delete overload is not the one that gets called.
struct BlockHeader {
    void *base;
    std::size_t size;
    std::size_t counted;  // 1 when this block was counted, so the free matches
    std::size_t pad;
};
const std::size_t kHeaderSize = sizeof(BlockHeader);  // 32 on every LP64 target

// The bump arena. Never reuses a freed block, so the address of the Nth
// allocation depends only on N and on the sizes before it -- which is exactly
// the property that makes the counts reproducible. 128 MiB of .bss; only the
// pages actually touched are ever committed, and the workloads below use a few
// megabytes in total.
const std::size_t kArenaBytes = 128u * 1024u * 1024u;
alignas(64) unsigned char g_arena[kArenaBytes];
std::size_t g_arena_used = 0;

void *ArenaAllocate(std::size_t n) {
    std::size_t rounded = (n + 63u) & ~static_cast<std::size_t>(63u);
    if (g_arena_used + rounded > kArenaBytes) {
        // Falling back to malloc here would silently reintroduce the very
        // nondeterminism the arena exists to remove, so refuse instead.
        std::fprintf(stderr,
                     "counter_probe: arena exhausted (%zu bytes); raise kArenaBytes\n",
                     kArenaBytes);
        std::exit(2);
    }
    void *p = g_arena + g_arena_used;
    g_arena_used += rounded;
    return p;
}

void *RawAllocate(std::size_t n, std::size_t alignment) {
    std::size_t slack = alignment > kHeaderSize ? alignment : 0;
    void *base = ArenaAllocate(n + kHeaderSize + slack);
    if (base == nullptr) {
        return nullptr;
    }
    std::uintptr_t p = reinterpret_cast<std::uintptr_t>(base) + kHeaderSize;
    if (alignment > kHeaderSize) {
        p = (p + alignment - 1) & ~static_cast<std::uintptr_t>(alignment - 1);
    }
    BlockHeader *h = reinterpret_cast<BlockHeader *>(p - kHeaderSize);
    h->base = base;
    h->size = n;
    h->counted = g_counting ? 1u : 0u;
    h->pad = 0;
    if (g_counting) {
        g_alloc.allocations += 1;
        g_alloc.bytes += n;
        g_alloc.live_bytes += n;
        if (g_alloc.live_bytes > g_alloc.peak_bytes) {
            g_alloc.peak_bytes = g_alloc.live_bytes;
        }
    }
    return reinterpret_cast<void *>(p);
}

void RawFree(void *p) {
    if (p == nullptr) {
        return;
    }
    BlockHeader *h = reinterpret_cast<BlockHeader *>(
            reinterpret_cast<std::uintptr_t>(p) - kHeaderSize);
    if (h->counted != 0u) {
        g_alloc.frees += 1;
        if (g_alloc.live_bytes >= h->size) {
            g_alloc.live_bytes -= h->size;
        }
    }
    // Deliberately does not return the memory: the accounting above is what the
    // report is made of, and reuse would make addresses depend on free order.
    h->counted = 0;
}

void ResetAlloc() {
    g_alloc.allocations = 0;
    g_alloc.frees = 0;
    g_alloc.bytes = 0;
    g_alloc.live_bytes = 0;
    g_alloc.peak_bytes = 0;
}

}  // namespace

void *operator new(std::size_t n) {
    void *p = RawAllocate(n, alignof(std::max_align_t));
    if (p == nullptr) throw std::bad_alloc();
    return p;
}
void *operator new[](std::size_t n) {
    void *p = RawAllocate(n, alignof(std::max_align_t));
    if (p == nullptr) throw std::bad_alloc();
    return p;
}
void *operator new(std::size_t n, const std::nothrow_t &) noexcept {
    return RawAllocate(n, alignof(std::max_align_t));
}
void *operator new[](std::size_t n, const std::nothrow_t &) noexcept {
    return RawAllocate(n, alignof(std::max_align_t));
}
void *operator new(std::size_t n, std::align_val_t a) {
    void *p = RawAllocate(n, static_cast<std::size_t>(a));
    if (p == nullptr) throw std::bad_alloc();
    return p;
}
void *operator new[](std::size_t n, std::align_val_t a) {
    void *p = RawAllocate(n, static_cast<std::size_t>(a));
    if (p == nullptr) throw std::bad_alloc();
    return p;
}
void operator delete(void *p) noexcept { RawFree(p); }
void operator delete[](void *p) noexcept { RawFree(p); }
void operator delete(void *p, std::size_t) noexcept { RawFree(p); }
void operator delete[](void *p, std::size_t) noexcept { RawFree(p); }
void operator delete(void *p, std::align_val_t) noexcept { RawFree(p); }
void operator delete[](void *p, std::align_val_t) noexcept { RawFree(p); }
void operator delete(void *p, std::size_t, std::align_val_t) noexcept { RawFree(p); }
void operator delete[](void *p, std::size_t, std::align_val_t) noexcept { RawFree(p); }
void operator delete(void *p, const std::nothrow_t &) noexcept { RawFree(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { RawFree(p); }

// ------------------------------------------------------------- counted key --

namespace {

struct KeyStats {
    std::size_t value_ctor;
    std::size_t copy_ctor;
    std::size_t move_ctor;
    std::size_t copy_assign;
    std::size_t move_assign;
    std::size_t dtor;
};

KeyStats g_key = {0, 0, 0, 0, 0, 0};
bool g_key_counting = false;

void ResetKey() { g_key = KeyStats{0, 0, 0, 0, 0, 0}; }

// A key whose every operation is recorded. Deliberately NOT nothrow-movable in
// any way the library could special-case: it is an ordinary well-behaved value
// type, which is what a user's key normally is.
class CountedKey {
public:
    CountedKey() : value_(0) {
        if (g_key_counting) ++g_key.value_ctor;
    }
    explicit CountedKey(std::uint64_t v) : value_(v) {
        if (g_key_counting) ++g_key.value_ctor;
    }
    CountedKey(const CountedKey &o) : value_(o.value_) {
        if (g_key_counting) ++g_key.copy_ctor;
    }
    CountedKey(CountedKey &&o) noexcept : value_(o.value_) {
        if (g_key_counting) ++g_key.move_ctor;
    }
    CountedKey &operator=(const CountedKey &o) {
        value_ = o.value_;
        if (g_key_counting) ++g_key.copy_assign;
        return *this;
    }
    CountedKey &operator=(CountedKey &&o) noexcept {
        value_ = o.value_;
        if (g_key_counting) ++g_key.move_assign;
        return *this;
    }
    ~CountedKey() {
        if (g_key_counting) ++g_key.dtor;
    }

    std::uint64_t value() const { return value_; }
    bool operator==(const CountedKey &o) const { return value_ == o.value_; }
    bool operator!=(const CountedKey &o) const { return value_ != o.value_; }

private:
    std::uint64_t value_;
};

struct CountedKeySeedHash {
    std::size_t operator()(const CountedKey &k, std::size_t seed) const {
        return fph::SimpleSeedHash<std::uint64_t>{}(k.value(), seed);
    }
};

// splitmix64: identical output on every implementation, unlike
// std::uniform_int_distribution. Fill keys are drawn from the top of the range
// so that they cannot collide with the small keys the workloads insert.
class DeterministicRng {
public:
    DeterministicRng() : init_seed(0x9E3779B97F4A7C15ull), state_(init_seed) {}
    explicit DeterministicRng(std::size_t seed) : init_seed(seed), state_(seed) {}

    void seed(std::uint64_t s = 0) {
        init_seed = static_cast<std::size_t>(s);
        state_ = s;
    }

    std::uint64_t Next() {
        state_ += 0x9E3779B97F4A7C15ull;
        std::uint64_t z = state_;
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }

    std::size_t init_seed;

protected:
    std::uint64_t state_;
};

class CountedKeyRng : public DeterministicRng {
public:
    using DeterministicRng::DeterministicRng;
    CountedKey operator()() { return CountedKey(Next() | (1ull << 63)); }
};

class Uint64Rng : public DeterministicRng {
public:
    using DeterministicRng::DeterministicRng;
    std::uint64_t operator()() { return Next() | (1ull << 63); }
};

// ------------------------------------------------------------- the reports --

const char *g_workload = "";

void ReportCounters(bool with_key_stats) {
    std::printf("%s.allocations %zu\n", g_workload, g_alloc.allocations);
    std::printf("%s.alloc_bytes %zu\n", g_workload, g_alloc.bytes);
    std::printf("%s.peak_bytes %zu\n", g_workload, g_alloc.peak_bytes);
    std::printf("%s.leaked_bytes %zu\n", g_workload, g_alloc.live_bytes);
    if (with_key_stats) {
        std::printf("%s.key_value_ctor %zu\n", g_workload, g_key.value_ctor);
        std::printf("%s.key_copy_ctor %zu\n", g_workload, g_key.copy_ctor);
        std::printf("%s.key_move_ctor %zu\n", g_workload, g_key.move_ctor);
        std::printf("%s.key_copy_assign %zu\n", g_workload, g_key.copy_assign);
        std::printf("%s.key_move_assign %zu\n", g_workload, g_key.move_assign);
    }
}

// A workload runs entirely inside the counting window and reports afterwards,
// so the numbers describe the table and nothing else.
template <class Body>
void RunWorkload(const char *name, bool with_key_stats, Body body) {
    g_workload = name;
    ResetAlloc();
    ResetKey();
    g_counting = true;
    g_key_counting = true;
    body();
    g_counting = false;
    g_key_counting = false;
    ReportCounters(with_key_stats);
}

// -------------------------------------------------------------- workloads --

const std::size_t kN = 2000;

using DynIntMap = fph::DynamicFphMap<std::uint64_t, std::uint64_t,
                                     fph::SimpleSeedHash<std::uint64_t>,
                                     std::equal_to<std::uint64_t>,
                                     std::allocator<std::pair<const std::uint64_t, std::uint64_t> >,
                                     std::uint32_t, Uint64Rng>;
using MetaIntMap = fph::MetaFphMap<std::uint64_t, std::uint64_t>;

using DynCountedSet = fph::DynamicFphSet<CountedKey, CountedKeySeedHash,
                                         std::equal_to<CountedKey>,
                                         std::allocator<CountedKey>,
                                         std::uint32_t, CountedKeyRng>;
using MetaCountedSet = fph::MetaFphSet<CountedKey, CountedKeySeedHash>;

using DynCountedMap = fph::DynamicFphMap<CountedKey, std::uint64_t, CountedKeySeedHash,
                                         std::equal_to<CountedKey>,
                                         std::allocator<std::pair<const CountedKey, std::uint64_t> >,
                                         std::uint32_t, CountedKeyRng>;
using MetaCountedMap = fph::MetaFphMap<CountedKey, std::uint64_t, CountedKeySeedHash>;

template <class Map>
void InsertIntMap() {
    Map m;
    m.reserve(kN);
    for (std::size_t i = 0; i < kN; ++i) {
        m.insert(std::make_pair(static_cast<std::uint64_t>(i * 7 + 1),
                                static_cast<std::uint64_t>(i)));
    }
    std::size_t found = 0;
    for (std::size_t i = 0; i < kN; ++i) {
        found += m.count(static_cast<std::uint64_t>(i * 7 + 1));
    }
    if (found != kN) {
        std::fprintf(stderr, "counter_probe: %s lost keys (%zu of %zu)\n",
                     g_workload, found, kN);
        std::exit(1);
    }
}

// Growth without reserve is the expensive path: the table rebuilds repeatedly.
template <class Map>
void GrowIntMap() {
    Map m;
    for (std::size_t i = 0; i < kN; ++i) {
        m.insert(std::make_pair(static_cast<std::uint64_t>(i * 7 + 1),
                                static_cast<std::uint64_t>(i)));
    }
    if (m.size() != kN) {
        std::fprintf(stderr, "counter_probe: %s size %zu != %zu\n",
                     g_workload, m.size(), kN);
        std::exit(1);
    }
}

template <class Set>
void InsertCountedSet() {
    Set s;
    s.reserve(kN);
    for (std::size_t i = 0; i < kN; ++i) {
        s.insert(CountedKey(static_cast<std::uint64_t>(i * 7 + 1)));
    }
    std::size_t found = 0;
    for (std::size_t i = 0; i < kN; ++i) {
        found += s.count(CountedKey(static_cast<std::uint64_t>(i * 7 + 1)));
    }
    if (found != kN) {
        std::fprintf(stderr, "counter_probe: %s lost keys\n", g_workload);
        std::exit(1);
    }
}

// rehash() relocates every element; the relocation loops are where the key
// copy counts live.
template <class Map>
void RehashCountedMap() {
    Map m;
    m.reserve(kN);
    for (std::size_t i = 0; i < kN; ++i) {
        m.insert(std::make_pair(CountedKey(static_cast<std::uint64_t>(i * 7 + 1)),
                                static_cast<std::uint64_t>(i)));
    }
    m.rehash(kN * 4);
    if (m.size() != kN) {
        std::fprintf(stderr, "counter_probe: %s size %zu != %zu\n",
                     g_workload, m.size(), kN);
        std::exit(1);
    }
}

// Copying a table is a whole second build; it is also the cheapest way to see
// whether a change made the copy constructor allocate more.
template <class Map>
void CopyCountedMap() {
    Map m;
    m.reserve(kN);
    for (std::size_t i = 0; i < kN; ++i) {
        m.insert(std::make_pair(CountedKey(static_cast<std::uint64_t>(i * 7 + 1)),
                                static_cast<std::uint64_t>(i)));
    }
    Map copy(m);
    if (copy.size() != m.size()) {
        std::fprintf(stderr, "counter_probe: %s copy size mismatch\n", g_workload);
        std::exit(1);
    }
}

}  // namespace

int main() {
    RunWorkload("dyn_map_reserve_insert_2000", false, InsertIntMap<DynIntMap>);
    RunWorkload("meta_map_reserve_insert_2000", false, InsertIntMap<MetaIntMap>);
    RunWorkload("dyn_map_grow_insert_2000", false, GrowIntMap<DynIntMap>);
    RunWorkload("meta_map_grow_insert_2000", false, GrowIntMap<MetaIntMap>);

    RunWorkload("dyn_set_counted_insert_2000", true, InsertCountedSet<DynCountedSet>);
    RunWorkload("meta_set_counted_insert_2000", true, InsertCountedSet<MetaCountedSet>);

    RunWorkload("dyn_map_counted_rehash_2000", true, RehashCountedMap<DynCountedMap>);
    RunWorkload("meta_map_counted_rehash_2000", true, RehashCountedMap<MetaCountedMap>);

    RunWorkload("dyn_map_counted_copy_2000", true, CopyCountedMap<DynCountedMap>);
    RunWorkload("meta_map_counted_copy_2000", true, CopyCountedMap<MetaCountedMap>);

    return 0;
}
