#include <cstdint>
#include <cstddef>
#include <cstring>
#include <random>
#include <cinttypes>
#include "fph/meta_fph_table.h"


uint64_t FastRand(uint64_t x) {
    x ^= x >> 33U;
    x *= UINT64_C(0xff51afd7ed558ccd);
    x ^= x >> 33U;
    return x;
}

int main() {

    constexpr size_t TEST_ITEM_SIZE = 1ULL << 22;
    constexpr size_t ITEM_BIT_SIZE = 4UL;

    using UnderlyingEntry = uint8_t;
    constexpr size_t UnderlyingEntrySize = TEST_ITEM_SIZE * (sizeof(UnderlyingEntry) * 8UL / ITEM_BIT_SIZE);
    static UnderlyingEntry underlying_arr[UnderlyingEntrySize];
    static constexpr UnderlyingEntry ITEM_MASK =
            fph::meta::detail::GenBitMask<UnderlyingEntry>(ITEM_BIT_SIZE);
    static uint32_t bench_table[TEST_ITEM_SIZE];
    memset(underlying_arr, 0, sizeof(underlying_arr));
    memset(bench_table, 0, sizeof(bench_table));
    fph::meta::detail::BitArrayView<UnderlyingEntry, ITEM_BIT_SIZE> bit_array(underlying_arr);
    uint64_t seed = std::random_device{}();
    uint64_t original_seed = FastRand(seed);
    seed = original_seed;
    uint64_t temp_sum = 0;
    for (size_t i = 0; i < TEST_ITEM_SIZE; ++i) {
        seed = FastRand(seed);
        size_t index = seed % TEST_ITEM_SIZE;
        auto value = seed & ITEM_MASK;
        bit_array.set(index, value);
        seed = FastRand(seed);
        index = seed % TEST_ITEM_SIZE;
        auto temp_value = bit_array.get(index);
        temp_sum += temp_value;
    }
    uint64_t temp_sum1 = temp_sum;
    seed = original_seed;
    temp_sum = 0;
    for (size_t i = 0; i < TEST_ITEM_SIZE; ++i) {
        seed = FastRand(seed);
        size_t index = seed % TEST_ITEM_SIZE;
        auto value = seed & ITEM_MASK;
        bench_table[index] = value;
        seed = FastRand(seed);
        index = seed % TEST_ITEM_SIZE;
        auto temp_value = bench_table[index];
        temp_sum += temp_value;
    }
    if (temp_sum != temp_sum1) {
        fprintf(stderr, "Error, temp_sum1: %" PRIu64 ", expected: %" PRIu64 "\n",
                temp_sum1, temp_sum);
        return -1;
    }
    fprintf(stdout, "Pass test, temp_sum: %" PRIu64 "\n", temp_sum);
    return 0;
}