#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"
#include <iostream>
#include <string_view>

using namespace std::literals;

class TestKeyClass {

public:
    explicit TestKeyClass(std::string  s): data(std::move(s)) {}

    // The key_type of fph table need to be copy constructible, assignment operators are not needed
    TestKeyClass(const TestKeyClass&o) = default;
    TestKeyClass(TestKeyClass&&o) = default;

    TestKeyClass& operator=(const TestKeyClass&o) = delete;
    TestKeyClass& operator=(TestKeyClass&&o) = delete;

    bool operator==(const TestKeyClass& o) const {
        return this->data == o.data;
    }

    std::string data;

};


struct TestKeyEqualTo {
    using is_transparent = void;
    using eq_type = std::equal_to<std::string_view>;
    bool operator()(const TestKeyClass& a, const std::string& b) const {
        return eq_type{}(a.data, b);
    }
    bool operator()(const TestKeyClass& a, std::string_view b) const {
        return eq_type{}(a.data, b);
    }
    bool operator()(const TestKeyClass& a, const TestKeyClass& b) const {
        return eq_type{}(a.data, b.data);
    }
    bool operator()(const TestKeyClass& a, const char* b) const {
        return eq_type{}(a.data, b);
    }
};

// The hash function of the custom key type need to take both a key and a seed
struct TestKeySeedHash {
    using is_transparent = void;
    using hash_type = fph::SimpleSeedHash<std::string_view>;

    size_t operator()(const TestKeyClass &src, size_t seed) const {
        return hash_type{}(src.data, seed);
    }

    size_t operator()(const std::string& src, size_t seed) const {
        return hash_type{}(src, seed);
    }

    size_t operator()(std::string_view src, size_t seed) const {
        return hash_type{}(src, seed);
    }

    size_t operator()(const char* src, size_t seed) const {
        return hash_type{}(src, seed);
    }
};

struct TestKeyHash {
    using is_transparent = void;
    using hash_type = std::hash<std::string_view>;

    size_t operator()(const std::string& key) const {
        return hash_type{}(key);
    }

    size_t operator()(const TestKeyClass &src) const {
        return hash_type{}(src.data);
    }

    size_t operator()(std::string_view key) const {
        return hash_type{}(key);
    }

    size_t operator()(const char* src) const {
        return hash_type{}(src);
    }
};

// a random key generator is needed for the Fph Hash Table;
// If using a custom class, a random generator of the key should be provided.
class KeyClassRNG {
public:
    KeyClassRNG(): string_gen(std::random_device{}()) {};

    TestKeyClass operator()() {
        return TestKeyClass(string_gen());
}


protected:
    fph::dynamic::RandomGenerator<std::string> string_gen;
};

template<class TestMap, class TestKeyClass>
void SampleTest() {
    TestMap fph_map = {{TestKeyClass("a"), 1}, {TestKeyClass("b"), 2}, {TestKeyClass("c"), 3},
                       {TestKeyClass("d"), 4} };


    std::cout << "map has elements: " << std::endl;
    for (const auto& [k, v]: fph_map) {
        std::cout << "(" << k.data << ", " << v << ") ";
    }
    std::cout << std::endl;

    fph_map.insert({TestKeyClass("e"), 5});
    auto &e_ref = fph_map.at(TestKeyClass("e"));
    std::cout << "value at e is " << e_ref << std::endl;
    fph_map.template try_emplace<>(TestKeyClass("f"), 6);
    const auto& f_ref = const_cast<const TestMap*>(&fph_map)->at(TestKeyClass("f"));
    (void)0;
    std::cout << "value at f is " << f_ref << std::endl;
    fph_map[TestKeyClass("g")] = 7;

    fph_map.erase(TestKeyClass("a"));
    auto const_find_it = const_cast<const TestMap*>(&fph_map)->find(TestKeyClass("b"));
    std::cout << "find key b value is " << const_find_it->second << std::endl;
    fph_map.erase(const_find_it);
    {
        auto temp_find_it = fph_map.find("c"sv);
        if (temp_find_it != fph_map.end()) {
            std::cout << "find value at c is " << temp_find_it->second <<
            std::endl;
        }
        auto &c_value = fph_map.at("c"sv);
        std::cout << "value at c is " << c_value << std::endl;

        auto &c_ref = fph_map["c"sv];
        std::cout << "value operator[] at c is " << c_ref << std::endl;
    }
    if (fph_map.contains("d"s)) {
        std::cout << "contains d in table" << std::endl;
    }
    std::cout << "count elements with key e: " << fph_map.count("e") << std::endl;

    std::cout << "Fph map now has elements: " << std::endl;
    for (const auto& [k, v]: fph_map) {
        std::cout << "(" << k.data << ", " << v << ") ";
    }
    std::cout << std::endl;

    if (fph_map.find(TestKeyClass("a")) == fph_map.end()) {
        std::cout << "Cannot find \"a\" in map" << std::endl;
    }
    if (fph_map.contains(TestKeyClass("b"))) {
        std::cout << "Found \"f\" in map" << std::endl;
    }
    std::cout << "Value with key \"g\" is "
              << fph_map.GetPointerNoCheck(TestKeyClass("g"))->second
              << std::endl;

    fph_map.clear();

    if (fph_map.empty()) {
        std::cout << "table is empty\n";
    }
}

void TestFphMap() {
    using KeyType = TestKeyClass;
    using MappedType = uint64_t;
    using TestHash = TestKeyHash;
    using KeyEqual = TestKeyEqualTo;
    using Allocator = std::allocator<std::pair<const KeyType, MappedType>>;
    using BucketParamType = uint32_t;
    using KeyRNG = KeyClassRNG;


    using DyFphMap = fph::DynamicFphMap<KeyType, MappedType, TestHash, KeyEqual, Allocator,
                                        BucketParamType , KeyRNG>;
    using FphMetaMap = fph::MetaFphMap<KeyType, MappedType, TestHash, KeyEqual, Allocator,
            BucketParamType>;

    std::cout << "DynamicFphMap" << std::endl;
    SampleTest<DyFphMap, TestKeyClass>();

    std::cout << std::endl << "MetaFphMap" << std::endl;
    SampleTest<FphMetaMap, TestKeyClass>();

}

int main() {
    TestFphMap();
    return 0;
}