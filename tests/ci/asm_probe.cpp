// Emits the lookup path as standalone symbols so its machine code can be
// compared byte-for-byte between two revisions. Machine-load independent:
// if the disassembly of these symbols is unchanged, the lookup path did not
// change, regardless of what else the patch touched.
#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"
#include <cstdint>
#include <string>

using DM = fph::DynamicFphMap<uint64_t, uint64_t>;
using MM = fph::MetaFphMap<uint64_t, uint64_t>;
using DS = fph::DynamicFphSet<uint64_t>;
using MS = fph::MetaFphSet<uint64_t>;
using DMS = fph::DynamicFphMap<std::string, uint64_t>;
using MMS = fph::MetaFphMap<std::string, uint64_t>;

#define NOINL extern "C" __attribute__((noinline))

// Absorbs the Mach-O section-start label (<ltmp0>) so every real probe below
// gets its own symbol header in the disassembly. Do not remove.
NOINL int fphprobe_aaa_anchor() { return 0; }

// --- dynamic table lookup path ---
NOINL uint64_t fphprobe_dm_find(DM& m, uint64_t k) {
    auto it = m.find(k);
    return it == m.end() ? 0u : it->second;
}
NOINL size_t fphprobe_dm_slotpos(const DM& m, uint64_t k) { return m.GetSlotPos(k); }
NOINL uint64_t fphprobe_dm_nocheck(DM& m, uint64_t k) { return m.GetPointerNoCheck(k)->second; }
NOINL bool fphprobe_ds_contains(const DS& s, uint64_t k) { return s.contains(k); }
NOINL size_t fphprobe_dm_count(const DM& m, uint64_t k) { return m.count(k); }
NOINL uint64_t fphprobe_dms_find(DMS& m, const std::string& k) {
    auto it = m.find(k);
    return it == m.end() ? 0u : it->second;
}

// --- meta table lookup path ---
NOINL uint64_t fphprobe_mm_find(MM& m, uint64_t k) {
    auto it = m.find(k);
    return it == m.end() ? 0u : it->second;
}
NOINL size_t fphprobe_mm_slotpos(const MM& m, uint64_t k) { return m.GetSlotPos(k); }
NOINL uint64_t fphprobe_mm_nocheck(MM& m, uint64_t k) { return m.GetPointerNoCheck(k)->second; }
NOINL bool fphprobe_ms_contains(const MS& s, uint64_t k) { return s.contains(k); }
NOINL size_t fphprobe_mm_count(const MM& m, uint64_t k) { return m.count(k); }
NOINL uint64_t fphprobe_mms_find(MMS& m, const std::string& k) {
    auto it = m.find(k);
    return it == m.end() ? 0u : it->second;
}

// --- hot object layout: any change here is a red flag ---
static_assert(sizeof(DM) > 0);
NOINL size_t fphprobe_sizeof_dm() { return sizeof(DM); }
NOINL size_t fphprobe_sizeof_mm() { return sizeof(MM); }
NOINL size_t fphprobe_sizeof_ds() { return sizeof(DS); }
NOINL size_t fphprobe_sizeof_ms() { return sizeof(MS); }
