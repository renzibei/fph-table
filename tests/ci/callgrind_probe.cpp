// Runs one lookup loop, once, with a valgrind collection window around it.
//
//   ./callgrind_probe <scenario>
//
// The table is built before the window opens. That is not an optimisation: the
// library is a perfect hash table, its build runs a randomised parameter search,
// and the search is both far larger than the loop and the part of the program
// whose cost has nothing to do with lookup. Counting it would drown the signal.
//
// The window is opened with callgrind client requests, so the same binary runs
// unchanged outside valgrind (the requests compile to no-ops there) and under
// `--instr-atstart=no --collect-atstart=no`, where nothing outside the window is
// instrumented or collected.
//
// `tests/ci/check-callgrind.sh` reads the resulting counts. See docs/ci.md.
//
// Scenarios match tests/ci/perf_probe.cpp so that the deterministic counts and
// the wall-clock report describe the same workloads.

#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#if defined(__has_include)
#if __has_include(<valgrind/callgrind.h>)
#include <valgrind/callgrind.h>
#define FPH_HAVE_CALLGRIND 1
#endif
#endif

#if defined(FPH_HAVE_CALLGRIND)
#define FPH_REGION_BEGIN()               \
    do {                                 \
        CALLGRIND_START_INSTRUMENTATION; \
        CALLGRIND_TOGGLE_COLLECT;        \
    } while (0)
#define FPH_REGION_END()                \
    do {                                \
        CALLGRIND_TOGGLE_COLLECT;       \
        CALLGRIND_STOP_INSTRUMENTATION; \
    } while (0)
const bool kHaveCallgrind = true;
#else
#define FPH_REGION_BEGIN() do { } while (0)
#define FPH_REGION_END()   do { } while (0)
const bool kHaveCallgrind = false;
#endif

namespace {

std::uint64_t SplitMix64(std::uint64_t &state) {
    state += 0x9E3779B97F4A7C15ull;
    std::uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

// Same keys, same count and same probe order as tests/ci/perf_probe.cpp.
const std::size_t kElements = 100000;
const std::size_t kProbes = 1 << 20;

std::vector<std::uint64_t> MakeKeys(std::size_t n, std::uint64_t seed) {
    std::uint64_t state = seed;
    std::vector<std::uint64_t> keys;
    keys.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
        keys.push_back(SplitMix64(state) | 1ull);
    }
    return keys;
}

// The loops are the unit of measurement, so none of them may be folded into the
// caller or specialised against a table the compiler can see through.
template <class Map>
__attribute__((noinline)) std::uint64_t LoopCount(
        const Map &m, const std::vector<std::uint64_t> &probes) {
    std::uint64_t sum = 0;
    for (std::size_t i = 0; i < probes.size(); ++i) sum += m.count(probes[i]);
    return sum;
}

template <class Map>
__attribute__((noinline)) std::uint64_t LoopNoCheck(
        const Map &m, const std::vector<std::uint64_t> &probes) {
    std::uint64_t sum = 0;
    for (std::size_t i = 0; i < probes.size(); ++i)
        sum += m.GetPointerNoCheck(probes[i])->second;
    return sum;
}

template <class Map>
__attribute__((noinline)) std::uint64_t LoopFind(
        Map &m, const std::vector<std::uint64_t> &probes) {
    std::uint64_t sum = 0;
    for (std::size_t i = 0; i < probes.size(); ++i) {
        typename Map::iterator it = m.find(probes[i]);
        if (it != m.end()) sum += it->second;
    }
    return sum;
}

enum Kind { kHit, kMiss, kFind };

template <class Map>
int Run(const char *scenario, Kind kind) {
    std::vector<std::uint64_t> keys = MakeKeys(kElements, 0x1234);
    Map m;
    m.reserve(kElements);
    for (std::size_t i = 0; i < keys.size(); ++i) {
        m.insert(std::make_pair(keys[i], static_cast<std::uint64_t>(i)));
    }

    std::vector<std::uint64_t> probes;
    if (kind == kMiss) {
        probes = MakeKeys(kProbes, 0xDEAD);   // disjoint from the keys
    } else {
        std::uint64_t state = 0x5678;
        probes.reserve(kProbes);
        for (std::size_t i = 0; i < kProbes; ++i) {
            probes.push_back(keys[SplitMix64(state) % keys.size()]);
        }
    }

    // One warm pass outside the window, so the counted pass is not measuring
    // first-touch page faults and cold instruction cache.
    std::uint64_t warm = 0;
    if (kind == kMiss)      warm = LoopCount(m, probes);
    else if (kind == kFind) warm = LoopFind(m, probes);
    else                    warm = LoopNoCheck(m, probes);

    std::uint64_t sum = 0;
    FPH_REGION_BEGIN();
    if (kind == kMiss)      sum = LoopCount(m, probes);
    else if (kind == kFind) sum = LoopFind(m, probes);
    else                    sum = LoopNoCheck(m, probes);
    FPH_REGION_END();

    // Printed so that a run which somehow optimised the loop away is visible
    // rather than silently reporting a small instruction count.
    std::printf("scenario %s\n", scenario);
    std::printf("callgrind %d\n", kHaveCallgrind ? 1 : 0);
    std::printf("checksum %llu %llu\n",
                static_cast<unsigned long long>(sum),
                static_cast<unsigned long long>(warm));
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    const char *scenario = argc > 1 ? argv[1] : "meta_map_miss";

    typedef fph::DynamicFphMap<std::uint64_t, std::uint64_t> DynMap;
    typedef fph::MetaFphMap<std::uint64_t, std::uint64_t> MetaMap;

    if (!std::strcmp(scenario, "dyn_map_hit"))   return Run<DynMap>(scenario, kHit);
    if (!std::strcmp(scenario, "dyn_map_miss"))  return Run<DynMap>(scenario, kMiss);
    if (!std::strcmp(scenario, "dyn_map_find"))  return Run<DynMap>(scenario, kFind);
    if (!std::strcmp(scenario, "meta_map_hit"))  return Run<MetaMap>(scenario, kHit);
    if (!std::strcmp(scenario, "meta_map_miss")) return Run<MetaMap>(scenario, kMiss);
    if (!std::strcmp(scenario, "meta_map_find")) return Run<MetaMap>(scenario, kFind);

    std::fprintf(stderr, "callgrind_probe: unknown scenario: %s\n", scenario);
    return 2;
}
