// Instantiates the public surface of all four containers so that the compile
// matrix has something to compile.
//
// This file is the thing `tests/ci/compile-matrix.sh` gates with -Wall -Wextra
// -Werror. It is deliberately written in portable standard C++17 -- no GNU
// attributes, no compiler builtins -- so that the same file can be pointed at
// MSVC when someone gets round to it. See docs/ci.md.
//
// Only APIs that a pristine checkout compiles belong here: an API that does not
// compile yet would turn this into a broken build rather than a gate.

#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace {

// Every expression result is folded into this so that nothing is optimised
// away and nothing is reported as unused.
std::size_t g_sink = 0;

template <class Map>
void ExerciseMap() {
    using key_type = typename Map::key_type;
    using mapped_type = typename Map::mapped_type;
    using value_type = typename Map::value_type;

    Map m;
    g_sink += m.size() + m.empty() + m.max_size();

    m.reserve(64);
    m.insert(value_type(key_type(1), mapped_type(1)));
    m.insert(std::make_pair(key_type(2), mapped_type(2)));
    m.emplace(key_type(3), mapped_type(3));
    m.try_emplace(key_type(4), mapped_type(4));
    m[key_type(5)] = mapped_type(5);

    std::vector<value_type> more;
    more.push_back(value_type(key_type(6), mapped_type(6)));
    more.push_back(value_type(key_type(7), mapped_type(7)));
    m.insert(more.begin(), more.end());

    const Map &cm = m;
    g_sink += cm.count(key_type(3));
    g_sink += cm.contains(key_type(3));
    g_sink += static_cast<std::size_t>(cm.find(key_type(3)) != cm.end());
    g_sink += static_cast<std::size_t>(m.find(key_type(3)) != m.end());
    g_sink += static_cast<std::size_t>(cm.at(key_type(3)));
    g_sink += static_cast<std::size_t>(m.at(key_type(3)));
    g_sink += cm.GetSlotPos(key_type(3));
    g_sink += static_cast<std::size_t>(cm.GetPointerNoCheck(key_type(3))->second);

    for (typename Map::const_iterator it = cm.begin(); it != cm.end(); ++it) {
        g_sink += static_cast<std::size_t>(it->second);
    }
    for (const value_type &v : m) {
        g_sink += static_cast<std::size_t>(v.second);
    }

    g_sink += static_cast<std::size_t>(m.load_factor() > 0.0);
    g_sink += static_cast<std::size_t>(m.max_load_factor() > 0.0);
    g_sink += m.bucket_count();
    g_sink += m.max_bucket_count();

    m.rehash(128);
    m.erase(key_type(1));
    m.erase(m.find(key_type(2)));

    Map copied(m);
    Map moved(std::move(copied));
    Map assigned;
    assigned = moved;
    Map move_assigned;
    move_assigned = std::move(moved);
    move_assigned.swap(assigned);
    g_sink += assigned.size() + move_assigned.size();

    m.clear();
    g_sink += m.size();
}

template <class Set>
void ExerciseSet() {
    using key_type = typename Set::key_type;

    Set s;
    g_sink += s.size() + s.empty() + s.max_size();

    s.reserve(64);
    s.insert(key_type(1));
    s.emplace(key_type(2));

    std::vector<key_type> more;
    more.push_back(key_type(3));
    more.push_back(key_type(4));
    s.insert(more.begin(), more.end());

    const Set &cs = s;
    g_sink += cs.count(key_type(1));
    g_sink += cs.contains(key_type(1));
    g_sink += static_cast<std::size_t>(cs.find(key_type(1)) != cs.end());
    g_sink += static_cast<std::size_t>(s.find(key_type(1)) != s.end());
    g_sink += cs.GetSlotPos(key_type(1));

    for (typename Set::const_iterator it = cs.begin(); it != cs.end(); ++it) {
        g_sink += static_cast<std::size_t>(*it != key_type(0));
    }

    g_sink += static_cast<std::size_t>(s.load_factor() > 0.0);
    g_sink += s.bucket_count();
    g_sink += s.max_bucket_count();

    s.rehash(128);
    s.erase(key_type(1));
    s.erase(s.find(key_type(2)));

    Set copied(s);
    Set moved(std::move(copied));
    Set assigned;
    assigned = moved;
    Set move_assigned;
    move_assigned = std::move(moved);
    move_assigned.swap(assigned);
    g_sink += assigned.size() + move_assigned.size();

    s.clear();
    g_sink += s.size();
}

// String keys go through a separate path (heap-allocated keys, a different
// SimpleSeedHash specialisation), so they are instantiated as well.
template <class Map>
void ExerciseStringKeyedMap() {
    Map m;
    m.reserve(16);
    m.insert(std::make_pair(std::string("alpha"), 1));
    m.emplace(std::string("beta"), 2);
    m.try_emplace(std::string("gamma"), 3);
    const Map &cm = m;
    g_sink += cm.count("alpha");
    g_sink += static_cast<std::size_t>(cm.find(std::string("beta")) != cm.end());
    g_sink += static_cast<std::size_t>(cm.at(std::string("gamma")));
    m.erase(std::string("alpha"));
    g_sink += m.size();
}

// Non-default bucket parameter widths select different index policies; each is
// a distinct instantiation of the whole table.
template <class BucketParam>
void ExerciseBucketWidths() {
    ExerciseMap<fph::DynamicFphMap<std::uint64_t, std::uint64_t,
                                   fph::SimpleSeedHash<std::uint64_t>,
                                   std::equal_to<std::uint64_t>,
                                   std::allocator<std::pair<const std::uint64_t, std::uint64_t> >,
                                   BucketParam> >();
    ExerciseMap<fph::MetaFphMap<std::uint64_t, std::uint64_t,
                                fph::SimpleSeedHash<std::uint64_t>,
                                std::equal_to<std::uint64_t>,
                                std::allocator<std::pair<const std::uint64_t, std::uint64_t> >,
                                BucketParam> >();
}

}  // namespace

int main() {
    ExerciseMap<fph::DynamicFphMap<std::uint64_t, std::uint64_t> >();
    ExerciseMap<fph::MetaFphMap<std::uint64_t, std::uint64_t> >();
    ExerciseMap<fph::DynamicFphMap<std::uint32_t, std::uint32_t> >();
    ExerciseMap<fph::MetaFphMap<std::uint32_t, std::uint32_t> >();

    ExerciseSet<fph::DynamicFphSet<std::uint64_t> >();
    ExerciseSet<fph::MetaFphSet<std::uint64_t> >();

    ExerciseStringKeyedMap<fph::DynamicFphMap<std::string, std::uint64_t> >();
    ExerciseStringKeyedMap<fph::MetaFphMap<std::string, std::uint64_t> >();

    ExerciseBucketWidths<std::uint8_t>();
    ExerciseBucketWidths<std::uint16_t>();
    ExerciseBucketWidths<std::uint32_t>();

    // The lower-case aliases are the documented spelling in the README.
    fph::dynamic_fph_map<std::uint64_t, std::uint64_t> dm;
    fph::dynamic_fph_set<std::uint64_t> ds;
    fph::meta_fph_map<std::uint64_t, std::uint64_t> mm;
    fph::meta_fph_set<std::uint64_t> ms;
    g_sink += dm.size() + ds.size() + mm.size() + ms.size();

    return g_sink == 0xffffffffu ? 1 : 0;
}
