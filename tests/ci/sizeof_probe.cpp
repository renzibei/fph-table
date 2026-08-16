// Prints sizeof/alignof for every container instantiation the CI watches.
//
// The table object itself is on the lookup path: a caller holds it by value or
// by reference and every find() dereferences its members, so its size and
// layout are performance-relevant, not cosmetic. `tests/ci/check-sizeof.sh`
// compares this output against tests/ci/baselines/sizeof.txt for EXACT
// equality -- growing is a regression, and shrinking means the layout moved.
//
// Output format, one record per line:
//   sizeof <name> <bytes>
//   alignof <name> <bytes>
//
// The last line is `probe_complete 1`. check-sizeof.sh requires it, so output
// that stops early is a failure rather than a short list that happens to match.

#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"

#include <cstdint>
#include <cstdio>
#include <string>

namespace {

template <class T>
void Report(const char *name) {
    std::printf("sizeof %s %zu\n", name, sizeof(T));
    std::printf("alignof %s %zu\n", name, alignof(T));
}

template <class Key, class Value, class BucketParam>
void ReportBucketWidth(const char *suffix) {
    using DMap = fph::DynamicFphMap<Key, Value, fph::SimpleSeedHash<Key>,
                                    std::equal_to<Key>,
                                    std::allocator<std::pair<const Key, Value> >,
                                    BucketParam>;
    using MMap = fph::MetaFphMap<Key, Value, fph::SimpleSeedHash<Key>,
                                 std::equal_to<Key>,
                                 std::allocator<std::pair<const Key, Value> >,
                                 BucketParam>;
    char name[128];
    std::snprintf(name, sizeof(name), "DynamicFphMap<u64,u64,%s>", suffix);
    Report<DMap>(name);
    std::snprintf(name, sizeof(name), "MetaFphMap<u64,u64,%s>", suffix);
    Report<MMap>(name);
}

}  // namespace

int main() {
    // The baseline is a single file rather than one per platform because the
    // measured sizes are identical on every LP64 target tried (linux-x86_64
    // and darwin-arm64, gcc and clang). This line lets check-sizeof.sh notice
    // when that assumption stops holding instead of reporting a false failure.
    std::printf("sizeof void* %zu\n", sizeof(void *));

    Report<fph::DynamicFphMap<std::uint64_t, std::uint64_t> >("DynamicFphMap<u64,u64>");
    Report<fph::DynamicFphSet<std::uint64_t> >("DynamicFphSet<u64>");
    Report<fph::MetaFphMap<std::uint64_t, std::uint64_t> >("MetaFphMap<u64,u64>");
    Report<fph::MetaFphSet<std::uint64_t> >("MetaFphSet<u64>");

    Report<fph::DynamicFphMap<std::uint32_t, std::uint32_t> >("DynamicFphMap<u32,u32>");
    Report<fph::MetaFphMap<std::uint32_t, std::uint32_t> >("MetaFphMap<u32,u32>");

    Report<fph::DynamicFphMap<std::string, std::uint64_t> >("DynamicFphMap<string,u64>");
    Report<fph::DynamicFphSet<std::string> >("DynamicFphSet<string>");
    Report<fph::MetaFphMap<std::string, std::uint64_t> >("MetaFphMap<string,u64>");
    Report<fph::MetaFphSet<std::string> >("MetaFphSet<string>");

    ReportBucketWidth<std::uint64_t, std::uint64_t, std::uint8_t>("u8");
    ReportBucketWidth<std::uint64_t, std::uint64_t, std::uint16_t>("u16");
    ReportBucketWidth<std::uint64_t, std::uint64_t, std::uint32_t>("u32");

    // The iterators are returned by value from find(); their size matters too.
    Report<fph::DynamicFphMap<std::uint64_t, std::uint64_t>::iterator>(
            "DynamicFphMap<u64,u64>::iterator");
    Report<fph::DynamicFphMap<std::uint64_t, std::uint64_t>::const_iterator>(
            "DynamicFphMap<u64,u64>::const_iterator");
    Report<fph::MetaFphMap<std::uint64_t, std::uint64_t>::iterator>(
            "MetaFphMap<u64,u64>::iterator");
    Report<fph::MetaFphMap<std::uint64_t, std::uint64_t>::const_iterator>(
            "MetaFphMap<u64,u64>::const_iterator");

    std::printf("probe_complete 1\n");
    return 0;
}
