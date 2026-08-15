// Times the lookup path. INFORMATIONAL ONLY -- nothing gates on this.
//
// A GitHub-hosted runner is a shared virtual machine. The measured noise floor
// on a dedicated, pinned machine for this library is 0.15-0.76%; on a merely
// busy machine it is 5.7-10.6% at p95 with excursions past 70%. A hosted runner
// is worse than the busy machine, so any threshold that would catch a real 3%
// lookup regression would also fire constantly on nothing at all. The gate is
// tests/ci/check-asm.sh; this program exists so a human can look at numbers,
// and it is run alongside a byte-identical control binary so that the reader
// can see the noise floor next to every figure.
//
// Reports the MINIMUM over the rounds, not the mean: under additive scheduler
// noise the minimum is the least contaminated estimator available.
//
// Output format, one record per line:
//   <scenario> <nanoseconds-per-operation-x1000> <checksum>
// (fixed point, so the shell can compare without a floating point library)

#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

namespace {

std::uint64_t SplitMix64(std::uint64_t &state) {
    state += 0x9E3779B97F4A7C15ull;
    std::uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

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

template <class Map>
void RunHit(const char *name, int rounds) {
    std::vector<std::uint64_t> keys = MakeKeys(kElements, 0x1234);
    Map m;
    m.reserve(kElements);
    for (std::size_t i = 0; i < keys.size(); ++i) {
        m.insert(std::make_pair(keys[i], static_cast<std::uint64_t>(i)));
    }

    // A fixed pseudo-random probe order, so the access pattern is the same in
    // every arm and in every round.
    std::uint64_t state = 0x5678;
    std::vector<std::uint64_t> order;
    order.reserve(kProbes);
    for (std::size_t i = 0; i < kProbes; ++i) {
        order.push_back(keys[SplitMix64(state) % keys.size()]);
    }

    double best = 0.0;
    std::uint64_t checksum = 0;
    for (int r = 0; r < rounds; ++r) {
        std::uint64_t sum = 0;
        std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
        for (std::size_t i = 0; i < order.size(); ++i) {
            sum += m.GetPointerNoCheck(order[i])->second;
        }
        std::chrono::steady_clock::time_point t1 = std::chrono::steady_clock::now();
        double ns = std::chrono::duration<double, std::nano>(t1 - t0).count() /
                    static_cast<double>(order.size());
        if (r == 0 || ns < best) best = ns;
        checksum ^= sum;
    }
    std::printf("%s %lld %llu\n", name, static_cast<long long>(best * 1000.0 + 0.5),
                static_cast<unsigned long long>(checksum));
}

template <class Map>
void RunMiss(const char *name, int rounds) {
    std::vector<std::uint64_t> keys = MakeKeys(kElements, 0x1234);
    Map m;
    m.reserve(kElements);
    for (std::size_t i = 0; i < keys.size(); ++i) {
        m.insert(std::make_pair(keys[i], static_cast<std::uint64_t>(i)));
    }
    std::vector<std::uint64_t> misses = MakeKeys(kProbes, 0xDEAD);

    double best = 0.0;
    std::uint64_t checksum = 0;
    for (int r = 0; r < rounds; ++r) {
        std::uint64_t found = 0;
        std::chrono::steady_clock::time_point t0 = std::chrono::steady_clock::now();
        for (std::size_t i = 0; i < misses.size(); ++i) {
            found += m.count(misses[i]);
        }
        std::chrono::steady_clock::time_point t1 = std::chrono::steady_clock::now();
        double ns = std::chrono::duration<double, std::nano>(t1 - t0).count() /
                    static_cast<double>(misses.size());
        if (r == 0 || ns < best) best = ns;
        checksum ^= found;
    }
    std::printf("%s %lld %llu\n", name, static_cast<long long>(best * 1000.0 + 0.5),
                static_cast<unsigned long long>(checksum));
}

}  // namespace

int main(int argc, char **argv) {
    int rounds = argc > 1 ? std::atoi(argv[1]) : 5;
    if (rounds < 1) rounds = 1;

    RunHit<fph::DynamicFphMap<std::uint64_t, std::uint64_t> >("dyn_map_hit", rounds);
    RunHit<fph::MetaFphMap<std::uint64_t, std::uint64_t> >("meta_map_hit", rounds);
    RunMiss<fph::DynamicFphMap<std::uint64_t, std::uint64_t> >("dyn_map_miss", rounds);
    RunMiss<fph::MetaFphMap<std::uint64_t, std::uint64_t> >("meta_map_miss", rounds);
    return 0;
}
