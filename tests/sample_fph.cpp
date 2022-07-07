#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"
#include <iostream>

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

// The hash function of the custom key type need to take both a key and a seed
struct TestKeySeedHash {
    size_t operator()(const TestKeyClass &src, size_t seed) const {
        return fph::MixSeedHash<std::string>{}(src.data, seed);
    }
};

struct TestKeyHash {
    size_t operator()(const TestKeyClass &src) const {
        return std::hash<std::string>{}(src.data);
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
}

void TestFphMap() {
    using KeyType = TestKeyClass;
    using MappedType = uint64_t;
    using TestHash = TestKeyHash;
    using Allocator = std::allocator<std::pair<const KeyType, MappedType>>;
    using BucketParamType = uint32_t;
    using KeyRNG = KeyClassRNG;

    using DyFphMap = fph::DynamicFphMap<KeyType, MappedType, TestHash, std::equal_to<>, Allocator,
                                        BucketParamType , KeyRNG>;
    using FphMetaMap = fph::MetaFphMap<KeyType, MappedType, TestHash, std::equal_to<>, Allocator,
            BucketParamType>;


//    using TestMap = FphMetaMap;
//    using TestMap = FphMap;
    std::cout << "DynamicFphMap" << std::endl;
    SampleTest<DyFphMap, TestKeyClass>();

    std::cout << std::endl << "MetaFphMap" << std::endl;
    SampleTest<FphMetaMap, TestKeyClass>();

}

int main() {
    TestFphMap();
    return 0;
}