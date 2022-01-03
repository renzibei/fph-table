# Flash Perfect Hash

The Flash Perfect Hash (FPH) library is a modern C++ implementation of a dynamic [perfect hash](https://en.wikipedia.org/wiki/Perfect_hash_function) 
table (no collisions for the hash), which makes the hash map/set extremely fast for lookup operations.

We provide two container classes `fph::DynamicFphSet` and `fph::DynamicFphMap`. The APIs of these two
classes are almost the same as those of `std::unordered_set` and `std::unordered_map`, but there are some 
minor differences, which we will explain in detail below. In order to compile this code, you need 
to use at least C++17 or newer standards.

Generally speaking, the containers here are suitable for the situation where the performance of the 
query is very important, and the number of insertions is small compared to the query, or the keys are fixed.


## Algorithm

The time for a hash table to find the key is determined by the cost of calculating the hash, the 
number of times the data is read from the memory, and the cost of each memory access.

Almost every hash table dedicated to optimizing query performance will take some measures to reduce 
the number of memory accesses. For example, Google's [absl hash table](https://abseil.io/blog/20180927-swisstables) 
uses metadata and SIMD instruction to reduce the number of memory fetches; robin hood hashing is
aimed at reduce the variance of probe distances, which can make the lookup more cache-friendly.

Perfect hashing, by definition, minimizes the number of hashes and the number of memory accesses. 
It only needs to fetch the memory once to get the required data from the slots. Of course, the fly 
in the ointment is that the perfect hash function itself requires a parameter space that is 
proportional to the number of keys. Fortunately, the extra required by FPH is not worth mentioning 
compared to the slots for storing data, and this space will not cause a significant increase in the cache miss rate.

The idea of FPH originates from the [FCH algorithm](https://dl.acm.org/doi/abs/10.1145/133160.133209),
which is a perfect hash algorithm suitable for implementation. With full awareness of modern computer system architecture, FPH 
has improved and optimized the FCH algorithm for query speed. In addition, we let the perfect hash table support dynamic modification, although the cost of dynamic modification is relatively high at present.

The FCH algorithm use a two-step method when choosing the hash method, which may bring branches to 
the pipeline. We skip a step to make the hashing process easier. This speeds up the query step, 
but also makes the process of constructing the hash slower.

In order to be able to dynamically add key values to the hash table, whenever a new key value makes 
the hash no longer a perfect hash, we will rebuild the hash table.

## Difference compared to std
1. The template parameter `SeedHash` is different from the `Hash` in STL, it has to be a functor
accept two arguments: both the key and the seed
2. If the key type is not a common type, you will have to provide a random generator for the key 
with the template parameter `RandomKeyGenerator`
3. The keys have to be CopyConstructible
4. The values have to be MoveConstructible
5. May invalidates any references and pointers to elements within the table after rehash

## Build
Requirement: C++ standard not older than C++17; currently only gcc/clang are supported

FPH library is a header-only library. So you can just add the header file to the header search path 
of your project to include it.

Or, you can FPH with CMake. Put this repo as a subdirectory of your project and then use it as a 
submodule of your cmake project. For instance, if you put `fph-table` directory under the `third-party`
directory of your project, you can add the following codes to your `CMakeLists.txt`
```cmake
add_subdirectory(third-party/fph-table)
target_link_libraries(your_target PRIVATE fph::fph_table)
```

When you have added the `fph-table` directory to your header, use can include the fph map/set by adding

`#include "fph/dynamic_fph_table.h"` to your codes.

## Test
In order to test that fph has no compile and run errors on your system, you can use the test code we 
provide using the following commands.


```
cd fph-table/tests
mkdir build
cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j4
./fph_table_tests
```

## Usage

The APIs are almost the same with the `std::unordered_set` and `std::unordered_map`.

`fph::DynamicFphSet<Key, SeedHash, KeyEqual, Allocator, BucketParamType, RandomKeyGenerator>` is the
fph set container. `fph::DynamicFphMap<Key, T, SeedHash, KeyEqual, Allocator, BucketParamType, RandomKeyGenerator>`
is the fph map container.

The following sample shows how to deal with the custom key class:

```c++
#include "fph/dynamic_fph_table.h"
#include <iostream>

class TestKeyClass {
public:
    explicit TestKeyClass(std::string  s): data(std::move(s)) {}

    // The key_type of fph table need to be copy constructable, assignment operator is not needed
    TestKeyClass(const TestKeyClass&o) = default;
    TestKeyClass(TestKeyClass&&o) = default;

    TestKeyClass& operator=(const TestKeyClass&o) = delete;
    TestKeyClass& operator=(TestKeyClass&&o) = delete;

    bool operator==(const TestKeyClass& o) const {
        return this->data == o.data;
    }

    std::string data;
protected:

};

struct TestKeySeedHash {
    size_t operator()(const TestKeyClass &src, size_t seed) const {
        return fph::MixSeedHash<std::string>{}(src.data, seed);
    }
};

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
    using SeedHash = TestKeySeedHash;
    using KeyRNG = KeyClassRNG;
    using FphMap = fph::DynamicFphMap<KeyType, MappedType, SeedHash, std::equal_to<>, std::allocator<std::pair<const KeyType, MappedType>>, uint32_t, KeyRNG>;

    FphMap fph_map = {{TestKeyClass("a"), 1}, {TestKeyClass("b"), 2}, {TestKeyClass("c"), 3}, {TestKeyClass("d"), 4} };

    std::cout << "Fph map has elements: " << std::endl;
    for (const auto& [k, v]: fph_map) {
        std::cout << "(" << k.data << ", " << v << ") ";
    }
    std::cout << std::endl;

    fph_map.insert({TestKeyClass("e"), 5});
    fph_map.try_emplace(TestKeyClass("f"), 6);
    fph_map[TestKeyClass("g")] = 7;
    fph_map.erase(TestKeyClass("a"));

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
    std::cout << "Value with key \"g\" is " << fph_map.GetPointerNoCheck(TestKeyClass("g"))->second << std::endl;
}

int main() {
    TestFphMap();
    return 0;
}
```

## Instructions for use
You can use the containers we provided to replace `std::unordered_set` or `std::unrodered_map` if 
you care more about lookup performance. Or if all you need is a perfect hash function i.e. a mapping
from keys to the integers in a limited range, you can use the 
`fph::DynamicFphSet::GetSlotPos(const key_type &key)` function to get the slot index of one key in 
the table, which is unique. The `GetSlotPos` is always faster than the `find` lookup as it does not
fetch data from the slots (which occupy most of the memory of a hash table).

The classic `find(const key_type&key)` function can be further optimized if the key is guaranteed
to be in the hash table. There is one comparison and branch instruction in the `find` function,
while the `pointer GetPointerNoCheck(const key_type &key)` function does not contain any comparison
or branch, as a result of which it's faster.

A 'slot' is the space reserved for a value(key for set, <K,V> for map). One slot in fph will at
most contain one value. We use an exponential multiple of 2 size for slots. Saying that the number 
of slots is m and the element number is n. n <= m and the size of slots will be 
`sizeof(value_type) * m` bytes

The speed of insertion is very sensitive to the max_load_factor parameter. If you use the
`insert(const value_type&)` function to construct a table, and you do care a little about the insert time, we suggest
that you use the default max_load_factor, which is around 0.6. But if you don't care about the
insert time, or you use the `insert(first, last)` or `Build()` to construct the table, and most importantly, you want
to save the memory size and cache size (which would probably accelerate the querying), you can
set a max_load_factor no larger than max_load_factor_upper_limit(), which should be 0.98.

If the range of your keys are limited, and they won't change at some time of your program,
you can set a large max_load_factor and then call rehash(element_size) to rehash the elements to
smaller slots if the load_factor can be smaller in that case. (Make sure almost no new keys will
be added to the table after this because the insert operation will be very slow when the
load_factor is very large.)

The extra hot memory space except slots during querying is the space for buckets (this concept is 
not the bucket in the STL unordered_set, it is from FCH algorithm), the size of
this extra memory is about `c * n / (log2(n) + 1) * sizeof(BucketParamType)` bytes. c is a
parameter that must be larger than 1.5. The larger c is, the quicker it will be for the
insert operations. BucketParamType is an unsigned type, and it must meet the condition that
`2^(number of bits of BucketParamType - 1)` is bigger than the element number. So you should choose
the BucketParamType that is just large enough but not too large if you don't want to waste the
memory and cache size. The memory size for this extra hot memory space will be slightly
larger than `c * n` bits.


We provide three kinds of SeedHash function for basic types: `fph::SimpleSeedHash<T>`,
`fph::MixSeedHash<T>` and `fph::StrongSeedHash<T>`;
The SimpleSeedHash has the fastest calculation speed and the weakest hash distribution, while the
StrongSeedHash is the slowest of them to calculate but has the best distribution of hash value.
The MixSeedHash is in the mid of them.
Take integer for an example, if the keys you want to insert is not uniformly distributed in
the integer interval of that type, then the hash value may probably not be uniformly distributed
in the hash type interval as well for a weak hash function. But with a strong hash function,
you can easily produce uniformly distributed hash values regardless of your input distribution.
If the hash values of the input keys are not uniformly distributed, there may be a failure in the
building of the hash table.

Tips: Know your input keys patterns before choosing the seed hash function. If your keys may
cause a failure in the building of the table, use a stronger seed hash function.

If you want to write your custom seed hash function for your own class, refer to the
fph::SimpleSeedHash<T>; the functor needs to take both a key and a seed (size_t) as input arguments and
return a size_t type hash value;
