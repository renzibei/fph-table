#include "fph/dynamic_fph_table.h"
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

void TestFphMap() {
    using KeyType = TestKeyClass;
    using MappedType = uint64_t;
//    using SeedHash = TestKeySeedHash;
    using Hash = TestKeyHash;
    using Allocator = std::allocator<std::pair<const KeyType, MappedType>>;
    using BucketParamType = uint32_t;
    using KeyRNG = KeyClassRNG;

    using FphMap = fph::DynamicFphMap<KeyType, MappedType, Hash, std::equal_to<>, Allocator,
                                        BucketParamType , KeyRNG>;

    FphMap fph_map = {{TestKeyClass("a"), 1}, {TestKeyClass("b"), 2}, {TestKeyClass("c"), 3},
                        {TestKeyClass("d"), 4} };

    std::cout << "Fph map has elements: " << std::endl;
    for (const auto& [k, v]: fph_map) {
        std::cout << "(" << k.data << ", " << v << ") ";
    }
    std::cout << std::endl;

    fph_map.insert({TestKeyClass("e"), 5});
    fph_map.template try_emplace<>(TestKeyClass("f"), 6);
    fph_map[TestKeyClass("g")] = 7;
    fph_map.erase(TestKeyClass("a"));
    fph_map.erase(const_cast<const FphMap*>(&fph_map)->find(TestKeyClass("b")));

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

int main() {
    TestFphMap();
    return 0;
}