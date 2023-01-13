#include "fph/dynamic_fph_table.h"
#include "fph/meta_fph_table.h"
#include "loghelper.h"

#include <unordered_set>
#include <unordered_map>
#include <cstdio>
#include <chrono>
#include <utility>
#include <vector>
#include <random>



#define TEST_TABLE_CORRECT 1

#ifdef FPH_HAVE_EXCEPTION
#   define TEST_TRY try
#   define TEST_CATCH(X) catch(X)
#else
#   define TEST_TRY if (true)
#   define TEST_CATCH(X) if (false)
#endif

enum TableType {
    FCH_TABLE = 0,
    DYNAMIC_FPH_TABLE,
    META_FPH_TABLE,
    STD_HASH_TABLE,
    ABSL_FLAT_TABLE,
    ROBIN_HOOD_FLAT_TABLE,
    SKA_FLAT_TABLE
};

std::string GetTableName(TableType table_type) {
    switch (table_type) {
        case FCH_TABLE:
            return "fch_map";
        case DYNAMIC_FPH_TABLE:
            return "dynamic_fph_map";
        case META_FPH_TABLE:
            return "meta_fph_map";
        case STD_HASH_TABLE:
            return "std::unordered_map";
        case ABSL_FLAT_TABLE:
            return "absl:flat_hash_map";
        case ROBIN_HOOD_FLAT_TABLE:
            return "robin_hood:unordered_flat_map";
        case SKA_FLAT_TABLE:
            return "ska::flat_hash_map";
    }
    return "";
}

enum LookupExpectation {
    KEY_IN = 0,
    KEY_NOT_IN,
    KEY_MAY_IN,
};

template <typename>
struct is_pair : std::false_type
{ };

template <typename T, typename U>
struct is_pair<std::pair<T, U>> : std::true_type
{ };

template<class T, typename = void>
struct SimpleGetKey {
    const T& operator()(const T& x) const {
        return x;
    }

    T& operator()(T& x) {
        return x;
    }

    T operator()(T&& x) {
        return std::move(x);
    }

};

template<class T>
struct SimpleGetKey<T, typename std::enable_if<is_pair<T>::value, void>::type> {

    using key_type = typename T::first_type;


    const key_type& operator()(const T& x) const {
        return x.first;
    }

    key_type& operator()(T& x) {
        return x.first;
    }

    key_type operator()(T&& x) {
        return std::move(x.first);
    }
};



class TestKeyClass {
public:
    explicit TestKeyClass(std::string  s): data(std::move(s)) {}
    TestKeyClass(const TestKeyClass& o): data(o.data) {}
//    TestKeyClass(TestKeyClass&& o) = delete;
    TestKeyClass(TestKeyClass&& o) noexcept : data(std::move(o.data)) {}
    TestKeyClass& operator=(const TestKeyClass&o) = delete;
    TestKeyClass& operator=(TestKeyClass&&o) = delete;


    bool operator==(const TestKeyClass& o) const {
        return this->data == o.data;
    }

    std::string data;
protected:

};

class TestValueClass {
public:
    explicit TestValueClass(uint64_t x): data(1, x) {}
    TestValueClass(const TestValueClass& o) = delete;
    TestValueClass(TestValueClass&& o) noexcept: data(std::move(o.data)) {}
//    TestValueClass(const TestValueClass& o) = default;

    TestValueClass& operator=(const TestValueClass& o) = delete;
    TestValueClass& operator=(TestValueClass&& o) = delete;

    bool operator==(const TestValueClass& o) const {
        return this->data == o.data;
    }

    std::vector<uint64_t> data;
};

struct TestKeyHash {
    size_t operator()(const TestKeyClass &src) const {
        return std::hash<std::string>{}(src.data);
    }
};

struct TestKeySeedHash {
    size_t operator()(const TestKeyClass &src, size_t seed) const {
        return fph::MixSeedHash<std::string>{}(src.data, seed);
    }
};

class KeyClassRNG {
public:
    KeyClassRNG(): init_seed(std::random_device{}()), string_gen(init_seed) {};
    KeyClassRNG(size_t seed):  init_seed(seed), string_gen(seed) {}

    TestKeyClass operator()() {
        return TestKeyClass(string_gen());
    }

    void seed(size_t seed) {
        init_seed = seed;
        string_gen.seed(seed);
    }

    size_t init_seed;

protected:
    fph::dynamic::RandomGenerator<std::string> string_gen;
};

class ValueClassRNG {
public:
    ValueClassRNG(): init_seed(std::random_device{}()), string_gen(init_seed) {};
    ValueClassRNG(size_t seed): init_seed(seed), string_gen(seed) {}

    TestValueClass operator()() {
        return TestValueClass(string_gen());
    }

    void seed(size_t seed) {
        init_seed = seed;
        string_gen.seed(seed);
    }

    size_t init_seed;

protected:
    fph::dynamic::RandomGenerator<uint64_t> string_gen;
//    fph::dynamic::RandomGenerator<std::string> string_gen;
};




using fph::dynamic::detail::ToString;

std::string ToString(const TestKeyClass &x) {
    return x.data;
}

template<class Table1, class Table2, class GetKey = SimpleGetKey<typename Table1::value_type>,
        class ValueEqual = std::equal_to<typename Table1::value_type>>
bool IsTableSame(const Table1 &table1, const Table2 &table2) {
    if (table1.size() != table2.size()) {
        return false;
    }
    size_t table_size = table2.size();
    size_t element_cnt = 0;
    for (const auto& pair :table1) {
        ++element_cnt;
        auto find_it = table2.find(GetKey{}(pair));
        if FPH_UNLIKELY(find_it == table2.end()) {
            LogHelper::log(Error, "Fail to find %s in table2, can find in table1 status: %d", ToString(GetKey{}(pair)).c_str(), table1.find(GetKey{}(pair)) != table1.end());
            return false;
        }
        if FPH_UNLIKELY(!ValueEqual{}(pair, *find_it)) {
            return false;
        }
    }
    if FPH_UNLIKELY(element_cnt != table_size) {
        LogHelper::log(Error, "Table 1 iterate num not equals to table size");
        return false;
    }
    element_cnt = 0;
    for (const auto& pair :table2) {
        ++element_cnt;
        auto find_it = table1.find(GetKey{}(pair));
        if FPH_UNLIKELY(find_it == table1.end()) {
            LogHelper::log(Error, "Fail to find %s in table1", ToString(GetKey{}(pair)).c_str());
            return false;
        }
        if FPH_UNLIKELY(!ValueEqual{}(pair, *find_it)) {
            return false;
        }
    }
    if FPH_UNLIKELY(element_cnt != table_size) {
        LogHelper::log(Error, "Table 2 iterate num not equals to table size");
        return false;
    }
    return true;
}



template< class Table, class BenchTable, class PairVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type> >
bool TestInsertCorrectness(Table &table, BenchTable &bench_table, PairVec &pair_vec1, PairVec &pair_vec2, size_t test_index = 0) {
    (void)test_index;
    TEST_TRY {
        table.clear();
        bench_table.clear();
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table and bench not same at beginning of insert");
            return false;
        }

        size_t pair_cnt = 0;
        if constexpr(std::is_copy_constructible_v<typename Table::value_type>) {
            for (const auto &pair: pair_vec1) {



                auto[bench_insert_it, bench_ok] = bench_table.insert(pair);
                auto[insert_it, ok] = table.insert(pair);
                if FPH_UNLIKELY(bench_ok != ok) {
                    LogHelper::log(Error, "insert flag not same, table: %d, bench_table: %d", ok,
                                   bench_ok);
                    return false;
                }
                if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
                    LogHelper::log(Error, "insert const& iterator not same");
                    return false;
                }

                // comment out the following comparing when not in debug
//                if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
//                    LogHelper::log(Error, "table not same during insert const&, pair_cnt: %lu", pair_cnt);
//                    return false;
//                }
                ++pair_cnt;
            }
            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
                LogHelper::log(Error, "table not same after insert const&");
                return false;
            }
        }


        pair_cnt = 0;
        if constexpr(std::is_move_constructible_v<typename Table::value_type>) {
            for (size_t i = 0; i < pair_vec1.size(); ++i) {
                auto[bench_insert_it, bench_ok] = bench_table.insert(std::move(pair_vec1[i]));
                auto[insert_it, ok] = table.insert(std::move(pair_vec2[i]));
                if (bench_ok != ok) {
                    return false;
                }
                if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
                    LogHelper::log(Error, "insert && iterator not same");
                    return false;
                }
                ++pair_cnt;
            }
            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
                LogHelper::log(Error, "table not same after insert &&");
                return false;
            }
        }
    }
    TEST_CATCH (const std::exception& e) {
        LogHelper::log(Error, "Catch exception in test insert");
        return false;
    }
    return true;
}

template<class Table, class BenchTable, class ValueVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type> >
bool TestEmplaceCorrectness1(Table &table, BenchTable &bench_table, ValueVec &value_vec1, ValueVec &value_vec2) {
    TEST_TRY {
        table.clear();
        bench_table.clear();
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same as the bench_table after clear()");
            return false;
        }

        size_t value_cnt = 0;
        if constexpr(std::is_copy_constructible_v<typename Table::value_type>) {
            for (const auto &value: value_vec1) {
                auto[bench_insert_it, bench_ok] = bench_table.emplace(value);
                auto[insert_it, ok] = table.emplace(value);
                if (bench_ok != ok) {
                    LogHelper::log(Error, "emplace ret flag not same, table: %d, bench: %d",
                                   ok, bench_ok);
                    return false;
                }
                if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
                    LogHelper::log(Error, "emplace1 const& iterator not same");
                    return false;
                }
                ++value_cnt;
            }
            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
                LogHelper::log(Error, "table not same after emplace test1 const&");
                return false;
            }
        }

        value_cnt = 0;
        for (size_t i = 0; i < value_vec1.size(); ++i) {
            auto[bench_insert_it, bench_ok] = bench_table.emplace(std::move(value_vec1[i]));
            auto[insert_it, ok] = table.emplace(std::move(value_vec2[i]));
            if (bench_ok != ok) {
                return false;
            }
            if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
                LogHelper::log(Error, "emplace1 && iterator not same");
                return false;
            }
            ++value_cnt;
        }
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same after emplace test1 &&");
            return false;
        }
    }
    TEST_CATCH (const std::exception &e) {
        LogHelper::log(Error, "catch error in test emplace1");
        return false;
    }
    return true;
}

template<class Table, class BenchTable, class KeyVec, class VVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type> >
bool TestEmplaceCorrectness2(Table &table, BenchTable &bench_table, KeyVec &k_vec1, VVec &v_vec1, KeyVec& k_vec2, VVec &v_vec2) {
    table.clear();
    bench_table.clear();
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        return false;
    }
    size_t value_cnt = 0;
    if constexpr (std::is_copy_constructible_v<typename Table::value_type>) {
        for (size_t i = 0; i < k_vec1.size(); ++i) {
            auto [bench_insert_it, bench_ok] = bench_table.emplace(k_vec1[i], v_vec1[i]);
            auto [insert_it, ok] = table.emplace(k_vec1[i], v_vec1[i]);
            if (bench_ok != ok) {
                return false;
            }
            if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
                LogHelper::log(Error, "emplace2 const& iterator not same");
                return false;
            }
            ++value_cnt;
        }
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same after emplace2 const&");
            return false;
        }
        table.clear();
        bench_table.clear();
    }

    for (size_t i = 0; i < k_vec1.size(); ++i) {
        auto [bench_insert_it, bench_ok] = bench_table.emplace(std::move(k_vec1[i]), std::move(v_vec1[i]));
        auto [insert_it, ok] = table.emplace(std::move(k_vec2[i]), std::move(v_vec2[i]));
        if (bench_ok != ok) {
            return false;
        }
        if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
            LogHelper::log(Error, "emplace2 && iterator not same");
            return false;
        }
        ++value_cnt;
    }
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        LogHelper::log(Error, "table not same after emplace2 &&");
        return false;
    }

    return true;
}

template<class Table, class BenchTable, class KeyVec, class VVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type> >
bool TestTryEmplaceCorrectness(Table &table, BenchTable &bench_table, KeyVec &k_vec1, VVec &v_vec1, KeyVec& k_vec2, VVec &v_vec2) {
    table.clear();
    bench_table.clear();
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        return false;
    }
    size_t value_cnt = 0;
    if constexpr (std::is_copy_constructible_v<typename Table::value_type>) {
        for (size_t i = 0; i < k_vec1.size(); ++i) {
            auto[bench_insert_it, bench_ok] = bench_table.try_emplace(k_vec1[i], v_vec1[i]);
            auto[insert_it, ok] = table.try_emplace(k_vec1[i], v_vec1[i]);
            if (bench_ok != ok) {
                return false;
            }
            if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
                LogHelper::log(Error, "try_emplace const& iterator not same");
                return false;
            }
            ++value_cnt;
        }
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same after try_emplace const&");
            return false;
        }
        table.clear();
        bench_table.clear();
    }
    for (size_t i = 0; i < k_vec1.size(); ++i) {
        auto [bench_insert_it, bench_ok] = bench_table.try_emplace(std::move(k_vec1[i]), std::move(v_vec1[i]));
        auto [insert_it, ok] = table.try_emplace(std::move(k_vec2[i]), std::move(v_vec2[i]));
        if (bench_ok != ok) {
            return false;
        }
        if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
            LogHelper::log(Error, "try_emplace && iterator not same");
            return false;
        }
        ++value_cnt;
    }
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        LogHelper::log(Error, "table not same after try_emplace &&");
        return false;
    }
    return true;
}

template<class Table, class BenchTable, class KeyVec, class VVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type> >
bool TestOperatorCorrectness(Table &table, BenchTable &bench_table, KeyVec &k_vec1, VVec &v_vec1, KeyVec& k_vec2, VVec &v_vec2) {
    table.clear();
    bench_table.clear();
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        return false;
    }
    using value_type = typename Table::value_type;
    size_t value_cnt = 0;
    if constexpr (std::is_copy_assignable_v<typename Table::value_type>) {
        for (size_t i = 0; i < k_vec1.size(); ++i) {
            auto &bench_ref = bench_table[k_vec1[i]] = v_vec1[i];
            auto &ref = table[k_vec1[i]] = v_vec1[i];
            if FPH_UNLIKELY(!ValueEqual{}(value_type(k_vec1[i], bench_ref), value_type(k_vec1[i], ref))) {
                LogHelper::log(Error, "operator[] const& iterator not same");
                return false;
            }
            ++value_cnt;
        }
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same after operator[] const&");
            return false;
        }
        table.clear();
        bench_table.clear();
    }
    if constexpr (std::is_move_assignable_v<typename Table::value_type>) {
        for (size_t i = 0; i < k_vec1.size(); ++i) {
            auto &bench_ref = bench_table[std::move(k_vec1[i])] = std::move(v_vec1[i]);
            auto temp_key = k_vec2[i];
            auto &ref = table[std::move(k_vec2[i])] = std::move(v_vec2[i]);
            if FPH_UNLIKELY(!ValueEqual{}(value_type(temp_key, bench_ref), value_type(temp_key, ref))) {
                LogHelper::log(Error, "operator[] && iterator not same");
                return false;
            }
            ++value_cnt;
        }
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same after operator[] &&");
            return false;
        }
    }
    return true;
}



template<TableType table_type, class Table, class GetKey = SimpleGetKey<typename Table::value_type>>
void PrintTableKeys(const Table &table) {
    LogHelper::log(Info, "Table %s has %lu keys", GetTableName(table_type).c_str(), table.size());
    for (auto it = table.begin(); it != table.end(); ++it) {
        fprintf(stderr, "%s, ", ToString(GetKey{}(*it)).c_str());
    }
    fprintf(stderr, "\n");
}

template< class Table, class BenchTable, class PairVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type> >
bool TestEraseCorrectness(Table &table, BenchTable &bench_table, PairVec &pair_vec1, PairVec &pair_vec2, size_t seed) {
    TEST_TRY {
        table.clear();
        bench_table.clear();
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not equal after clear at beginning of erase test");
            return false;
        }

        std::mt19937_64 random_engine(seed);
        std::uniform_int_distribution<size_t> seed_gen;

        size_t pair_cnt = 0;
        std::vector<typename Table::key_type> key_seq_vec;
        std::vector<bool> operation_seq_vec;
        key_seq_vec.reserve(pair_vec1.size());
        operation_seq_vec.reserve(pair_vec1.size());
        for (size_t i = 0; i < pair_vec1.size(); ++i) {
//            const auto &pair = pair_vec[i];
            auto temp_seed = seed_gen(random_engine);


//            bool do_erase_flag = false;

            if (i > 0 && temp_seed % 2U == 1U) {
                size_t try_erase_pos = seed_gen(random_engine) % i;
                const auto &try_erase_pair = pair_vec1[try_erase_pos];
                const auto &temp_key = GetKey{}(try_erase_pair);

                key_seq_vec.push_back(temp_key);
                operation_seq_vec.push_back(false);
//                do_erase_flag = true;
//                last_erase_pair_index = try_erase_pos;
                if (bench_table.find(temp_key) != bench_table.end()) {


                    auto seed2 = seed_gen(random_engine);
                    if (seed2 % 2U == 1U) {
                        auto bench_erase_size = bench_table.erase(temp_key);
                        auto table_erase_size = table.erase(temp_key);
                        if FPH_UNLIKELY(bench_erase_size != table_erase_size) {
                            LogHelper::log(Error, "Erase by const& key return not same, bench: %lu, table_erase: %lu",
                                           bench_erase_size, table_erase_size);
                            return false;
                        }
                    } else {
                        bench_table.erase(bench_table.find(temp_key));
                        table.erase(table.find(temp_key));
                    }
                }
            }
            key_seq_vec.push_back(GetKey{}(pair_vec1[i]));
            operation_seq_vec.push_back(true);
            auto[bench_insert_it, bench_ok] = bench_table.insert(std::move(pair_vec1[i]));
            auto[insert_it, ok] = table.insert(std::move(pair_vec2[i]));
            if FPH_UNLIKELY(bench_ok != ok) {
                LogHelper::log(Error, "insert ret flag not same, table: %d, bench: %d",
                               ok, bench_ok);
                return false;
            }
            if FPH_UNLIKELY(!ValueEqual{}(*bench_insert_it, *insert_it)) {
                LogHelper::log(Error, "insert const& iterator not same in erase test");
                return false;
            }
//            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
//                LogHelper::log(Error, "table not same after one insert in erase, insert key: %s, "
//                                      "pair_cnt: %lu, do_erase: %d, last_erase_key: %s",
//                               std::to_string(GetKey{}(pair)).c_str(), pair_cnt, do_erase_flag,
//                               std::to_string(GetKey{}(pair_vec[last_erase_pair_index])).c_str());
//                LogHelper::log(Error, "The key seq are: ");
//                for (const auto& key: key_seq_vec) {
//                    fprintf(stderr, "%s, ", std::to_string(key).c_str());
//                }
//                fprintf(stderr, "\n");
//                LogHelper::log(Error, "The operation seq are: ");
//                for (auto op: operation_seq_vec) {
//                    fprintf(stderr, "%d, ", int(op));
//                }
//                fprintf(stderr, "\n");
//                return false;
//            }
            ++pair_cnt;
        }
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same after random erase");
            return false;
        }

        for (auto it = bench_table.begin(); it != bench_table.end();) {
            auto temp_key = GetKey{}(*it);
            table.erase(table.find(temp_key));
            it = bench_table.erase(it);
//            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
//                LogHelper::log(Error, "table not same during erase key %s in past half", std::to_string(temp_key).c_str());
//                return false;
//            }
        }

        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "table not same after erase all");
            return false;
        }
    }
    TEST_CATCH (const std::exception& e) {
        LogHelper::log(Error, "Catch exception in test erase");
        return false;
    }
    return true;
}

template<TableType table_type, class Table, class PairVec, class GetKey = SimpleGetKey<typename PairVec::value_type>>
void ConstructTable(Table &table, const PairVec &pair_vec, size_t seed, double c = 2.0, bool do_reserve = true, bool do_rehash = false) {
    table.clear();
    if constexpr (table_type == FCH_TABLE) {
        table.Init(pair_vec.begin(), pair_vec.end(), seed, true, c);
    }
    else {
        if (do_reserve) {
            table.reserve(pair_vec.size());
        }
        for (size_t i = 0; i < pair_vec.size(); ++i) {
            const auto &pair = pair_vec[i];
            if constexpr (table_type == ROBIN_HOOD_FLAT_TABLE) {
                table[GetKey{}(pair)] = pair.second;
            }
            else {
                table.insert(pair);
            }
        }
        if constexpr (table_type == DYNAMIC_FPH_TABLE || table_type == META_FPH_TABLE) {
            if (do_rehash) {
                if (table.load_factor() < 0.45) {
                    table.max_load_factor(0.9);
                    table.rehash(table.size());
                }
            }
        }
    }
}

template<class Table, class BenchTable, class PairVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type>>
bool TestPartEraseAndInsert(Table &table, BenchTable &bench_table, PairVec &pair_vec) {
    size_t ele_num = pair_vec.size();
    if (table.size() != bench_table.size()) {
        LogHelper::log(Error, "element size in table not equal to pair_vec in test part erase");
        return false;
    }
    size_t half_ele_num = ele_num / 2U;
    for (size_t i = 0; i < half_ele_num; ++i) {
        if (bench_table.find(GetKey{}(pair_vec[i])) != bench_table.end()) {
            bench_table.erase(GetKey{}(pair_vec[i]));
            table.erase(GetKey{}(pair_vec[i]));
        }

    }
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        LogHelper::log(Error, "Table not same after erase half");
        return false;
    }
    for (size_t i = 0; i < half_ele_num; ++i) {
        bench_table.insert(pair_vec[i]);
        table.insert(pair_vec[i]);
    }
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        LogHelper::log(Error, "Table not same after insert half");
    }
    ConstructTable<DYNAMIC_FPH_TABLE>(table, pair_vec, 0);
    ConstructTable<STD_HASH_TABLE>(bench_table, pair_vec, 0);
    if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
        LogHelper::log(Error, "Table not same after re build in part Erase");
        return false;
    }
    return true;
}

template<class Table, class BenchTable, class PairVec, class GetKey = SimpleGetKey<typename Table::value_type>,
        class ValueEqual = std::equal_to<typename Table::value_type>>
bool TestCopyAndMoveCorrect(Table &table, BenchTable &bench_table, PairVec &pair_vec) {
    TEST_TRY {
        ConstructTable<DYNAMIC_FPH_TABLE>(table, pair_vec, 0);
        ConstructTable<STD_HASH_TABLE>(bench_table, pair_vec, 0);
        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)) {
            LogHelper::log(Error, "Table not same after construct");
            return false;
        }
    }
    TEST_CATCH (std::exception &e) {
        LogHelper::log(Error, "Catch exception in the beginning construct of test copy");
        return false;
    }


    TEST_TRY {
        for (size_t t = 0; t < 2; ++t) {

            Table *temp_table_ptr = new Table(table);
            table.clear();
            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(*temp_table_ptr, bench_table)
                || !TestPartEraseAndInsert<Table, BenchTable, PairVec, GetKey, ValueEqual>
                    (*temp_table_ptr, bench_table, pair_vec)) {
                LogHelper::log(Error, "Error in table copy constructor");
                return false;
            }


            table = *temp_table_ptr;
            delete temp_table_ptr;
            temp_table_ptr = nullptr;
            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)
                || !TestPartEraseAndInsert<Table, BenchTable, PairVec, GetKey, ValueEqual>
                    (table, bench_table, pair_vec)) {
                LogHelper::log(Error, "Error in table copy assignment");
                return false;
            }

            Table *temp_table2_ptr = new Table(std::move(table));
            table.clear();
            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(*temp_table2_ptr, bench_table)
                || !TestPartEraseAndInsert<Table, BenchTable, PairVec, GetKey, ValueEqual>
                    (*temp_table2_ptr, bench_table, pair_vec)) {
                LogHelper::log(Error, "Error in table move constructor");
                return false;
            }


            table = std::move(*temp_table2_ptr);
            delete temp_table2_ptr;
            temp_table2_ptr = nullptr;
            if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(table, bench_table)
                || !TestPartEraseAndInsert<Table, BenchTable, PairVec, GetKey, ValueEqual>
                    (table, bench_table, pair_vec)) {
                LogHelper::log(Error, "Error in table move assignment");
                return false;
            }

//        temp_table.clear();
//        ConstructTable<DYNAMIC_FPH_TABLE>(temp_table, pair_vec, 0);
//        if (!IsTableSame<Table, BenchTable, GetKey, ValueEqual>(temp_table, bench_table)
//            || !TestPartEraseAndInsert<Table, BenchTable, PairVec, GetKey, ValueEqual>
//                (temp_table, bench_table, pair_vec)) {
//            LogHelper::log(Error, "Error in for use with moved table");
//            return false;
//        }
        }
    }
    TEST_CATCH (std::exception &e) {
        LogHelper::log(Error, "Catch exception in test copy and move");
        return false;
    }
    return true;
}

template <class Table>
void Clear(Table *&table_ptr, size_t seed) {
    if (seed % 4 == 1) {
        delete table_ptr;
        table_ptr = new Table();
    }
    else {
        table_ptr->clear();
    }
}

template<typename T>
using base_type = typename std::remove_cv<typename std::remove_reference<T>::type>::type;

template<typename T1, typename T2, typename = void>
struct is_base_same : std::false_type {};

template<typename T1, typename T2>
struct is_base_same<T1, T2, typename
std::enable_if<std::is_same<base_type<T1>, base_type<T2>>::value>::type> : std::true_type {};



template<class PairVec, class GetKey = SimpleGetKey<typename PairVec::value_type>>
void PrintPairVec(const PairVec &pair_vec) {
    if (pair_vec.size() < 300ULL) {
        LogHelper::log(Info, "pair vec has %lu elements", pair_vec.size());
        for (const auto &pair: pair_vec) {
            fprintf(stderr, "%s, ", ToString(GetKey{}(pair)).c_str());
        }
        fprintf(stderr, "\n");
    }
}

void HandleExpPtr(std::exception_ptr eptr) // passing by value is ok
{
    TEST_TRY {
        if (eptr) {
            std::rethrow_exception(eptr);
        }
    } TEST_CATCH(const std::exception& e) {
        LogHelper::log(Error, "Caught exception");
    }
}



template<class Table, class BenchTable, class ValueRandomGen>
bool TestInitList(size_t seed, ValueRandomGen value_gen) {
    if constexpr (std::is_copy_constructible_v<typename Table::value_type>) {
        std::mt19937_64 int_engine(seed);
        {
            size_t temp_seed = int_engine();
            value_gen.seed(temp_seed);
            BenchTable bench_table{value_gen(), value_gen(), value_gen(), value_gen(), value_gen(),
                                   value_gen()};
            value_gen.seed(temp_seed);
            Table table{value_gen(), value_gen(), value_gen(), value_gen(), value_gen(),
                        value_gen()};

            if (!IsTableSame(table, bench_table)) {
                LogHelper::log(Error, "Table not same after using init list construct");
                return false;
            }
        }
        {
            size_t temp_seed = int_engine();
            value_gen.seed(temp_seed);
            BenchTable bench_table;
            bench_table.insert(
                    {value_gen(), value_gen(), value_gen(), value_gen(), value_gen(), value_gen()});
            value_gen.seed(temp_seed);
            Table table;
            table.insert(
                    {value_gen(), value_gen(), value_gen(), value_gen(), value_gen(), value_gen()});

            if (!IsTableSame(table, bench_table)) {
                LogHelper::log(Error, "Table not same after using init list construct");
                return false;
            }
        }
    }
    return true;
}

template<class ValueRandomGen, class Table, class BenchTable>
bool TestCorrectness(size_t max_elem_num, size_t test_time) {
    std::vector<size_t> test_elem_num_array = {0, max_elem_num};
    static std::random_device random_device;
    auto test_seed = random_device();
//    size_t test_seed = 3499889938ULL;
//    LogHelper::log(Debug, "test_seed: %lu", test_seed);
    std::mt19937_64 random_engine(test_seed);
    std::uniform_int_distribution<size_t> size_gen;
    using value_type = typename Table::value_type;
    using key_type = typename Table::key_type;


    std::vector<value_type> src_vec1, src_vec2;
    src_vec1.reserve(max_elem_num);
    src_vec2.reserve(max_elem_num);

    for (size_t i = 0; i < test_time; ++i) {
        test_elem_num_array.push_back(size_gen(random_engine) % (max_elem_num + 1UL));
    }
//    using BenchTable = std::unordered_map<KeyType, ValueType>;
    ValueRandomGen value_gen{};
    BenchTable bench_table;
    size_t test_index = 0;
    Table *table_ptr = new Table();

    auto gen_seed = value_gen.init_seed;

    TEST_TRY {

        const size_t start_k = 0;

        if (!TestInitList<Table, BenchTable>(gen_seed, value_gen)) {
            LogHelper::log(Error, "Error in test initlist");
            return false;
        }


        for (size_t k = start_k; k < test_elem_num_array.size(); ++k) {
            auto ele_num = test_elem_num_array[k];
            ++test_index;


            src_vec1.clear();
            src_vec2.clear();
            auto cur_seed = random_engine();
            value_gen.seed(cur_seed);
            for (size_t i = 0; i < ele_num; ++i) {
                src_vec1.push_back(value_gen());
            }
            value_gen.seed(cur_seed);
            for (size_t i = 0; i < ele_num; ++i) {
                src_vec2.push_back(value_gen());
            }

            bool do_reserve = size_gen(random_engine) & 0x1U;
            if (do_reserve) {
                table_ptr->reserve(ele_num);
            }

            if (!TestInsertCorrectness(*table_ptr, bench_table, src_vec1, src_vec2, test_index)) {
                LogHelper::log(Error,
                               "Fail to pass insert correctness test, element num: %lu, test_index: %lu, test_seed: %lu, gen_seed: %lu",
                               ele_num, test_index, test_seed, gen_seed);
#if FPH_DEBUG_ERROR
                table_ptr->PrintTableParams();
//                PrintPairVec(src_vec1);
#endif

                return false;
            }
            Clear(table_ptr, test_index);

            if constexpr (std::is_copy_constructible_v<value_type>) {
                src_vec1.clear();
                src_vec2.clear();
                cur_seed = random_engine();
                value_gen.seed(cur_seed);
                for (size_t i = 0; i < ele_num; ++i) {
                    src_vec1.push_back(value_gen());
                }
                value_gen.seed(cur_seed);
                for (size_t i = 0; i < ele_num; ++i) {
                    src_vec2.push_back(value_gen());
                }
                if (!TestCopyAndMoveCorrect(*table_ptr, bench_table, src_vec1)) {

                    LogHelper::log(Error, "Fail to pass copy and move test, element num: %lu, test_seed: %lu, gen_seed: %lu", ele_num, test_seed, gen_seed);
#if FPH_DEBUG_ERROR
                    table_ptr->PrintTableParams();
                    PrintPairVec(src_vec1);
#endif
                    return false;
                }
                Clear(table_ptr, test_index);
            }


            src_vec1.clear();
            src_vec2.clear();
            cur_seed = random_engine();
            value_gen.seed(cur_seed);
            for (size_t i = 0; i < ele_num; ++i) {
                src_vec1.push_back(value_gen());
            }
            value_gen.seed(cur_seed);
            for (size_t i = 0; i < ele_num; ++i) {
                src_vec2.push_back(value_gen());
            }
            if (!TestEmplaceCorrectness1(*table_ptr, bench_table, src_vec1, src_vec2)) {
                LogHelper::log(Error, "Fail to pass emplace correctness test, element num: %lu, test_seed: %lu, gen_seed: %lu",
                               ele_num, test_seed, gen_seed);
#if FPH_DEBUG_ERROR
                table_ptr->PrintTableParams();
//                PrintPairVec(src_vec);
#endif
                return false;
            }
            Clear(table_ptr, test_index);

            src_vec1.clear();
            src_vec2.clear();
            cur_seed = random_engine();
            value_gen.seed(cur_seed);
            for (size_t i = 0; i < ele_num; ++i) {
                src_vec1.push_back(value_gen());
            }
            value_gen.seed(cur_seed);
            for (size_t i = 0; i < ele_num; ++i) {
                src_vec2.push_back(value_gen());
            }
            if (!TestEraseCorrectness(*table_ptr, bench_table, src_vec1, src_vec2, size_gen(random_engine))) {
                LogHelper::log(Error,
                               "Fail to pass erase correctness test, element num: %lu, test_index: %lu, test_seed: %lu, gen_seed: %lu",
                               ele_num, test_index, test_seed, gen_seed);
#if FPH_DEBUG_ERROR
                table_ptr->PrintTableParams();
//                PrintPairVec(src_vec);
                PrintTableKeys<DYNAMIC_FPH_TABLE>(*table_ptr);
                PrintTableKeys<STD_HASH_TABLE>(bench_table);
#endif
                return false;
            }
            Clear(table_ptr, test_index);


            if constexpr(is_pair<value_type>::value) {
                if constexpr (is_base_same<typename value_type::first_type, key_type>::value) {
                    std::vector<key_type> k_vec1, k_vec2;
                    std::vector<typename value_type::second_type> v_vec1, v_vec2;
                    k_vec1.reserve(ele_num);
                    v_vec1.reserve(ele_num);
                    k_vec2.reserve(ele_num);
                    v_vec2.reserve(ele_num);
                    cur_seed = random_engine();
                    value_gen.seed(cur_seed);
                    for (size_t i = 0; i < ele_num; ++i) {
                        auto temp_pair = value_gen();
                        k_vec1.push_back(std::move(temp_pair.first));
                        v_vec1.push_back(std::move(temp_pair.second));
                    }
                    value_gen.seed(cur_seed);
                    for (size_t i = 0; i < ele_num; ++i) {
                        auto temp_pair = value_gen();
                        k_vec2.push_back(std::move(temp_pair.first));
                        v_vec2.push_back(std::move(temp_pair.second));
                    }
                    if (!TestEmplaceCorrectness2(*table_ptr, bench_table, k_vec1, v_vec1, k_vec2, v_vec2)) {
                        LogHelper::log(Error,
                                       "Fail to pass emplace2 correctness test, element num: %lu",
                                       ele_num);
                        return false;
                    }
                    Clear(table_ptr, test_index);

                    k_vec1.clear(); k_vec2.clear();
                    v_vec1.clear(); v_vec2.clear();
                    cur_seed = random_engine();
                    value_gen.seed(cur_seed);
                    for (size_t i = 0; i < ele_num; ++i) {
                        auto temp_pair = value_gen();
                        k_vec1.push_back(std::move(temp_pair.first));
                        v_vec1.push_back(std::move(temp_pair.second));
                    }
                    value_gen.seed(cur_seed);
                    for (size_t i = 0; i < ele_num; ++i) {
                        auto temp_pair = value_gen();
                        k_vec2.push_back(std::move(temp_pair.first));
                        v_vec2.push_back(std::move(temp_pair.second));
                    }
                    if (!TestTryEmplaceCorrectness(*table_ptr, bench_table, k_vec1, v_vec1, k_vec2, v_vec2)) {
                        LogHelper::log(Error,
                                       "Fail to pass try_emplace correctness test, element num: %lu",
                                       ele_num);
                        return false;
                    }
                    Clear(table_ptr, test_index);

                    k_vec1.clear(); k_vec2.clear();
                    v_vec1.clear(); v_vec2.clear();
                    cur_seed = random_engine();
                    value_gen.seed(cur_seed);
                    for (size_t i = 0; i < ele_num; ++i) {
                        auto temp_pair = value_gen();
                        k_vec1.push_back(std::move(temp_pair.first));
                        v_vec1.push_back(std::move(temp_pair.second));
                    }
                    value_gen.seed(cur_seed);
                    for (size_t i = 0; i < ele_num; ++i) {
                        auto temp_pair = value_gen();
                        k_vec2.push_back(std::move(temp_pair.first));
                        v_vec2.push_back(std::move(temp_pair.second));
                    }

                    if (!TestOperatorCorrectness(*table_ptr, bench_table, k_vec1, v_vec1, k_vec2, v_vec2)) {
                        LogHelper::log(Error,
                                       "Fail to pass operator[] correctness test, element num: %lu",
                                       ele_num);
                        return false;
                    }
                    Clear(table_ptr, test_index);
                }
            }
        }
        delete table_ptr;

    } TEST_CATCH(...) {

        auto e_ptr = std::current_exception();
        LogHelper::log(Error, "Got exception");
        HandleExpPtr(e_ptr);
        return false;
    }

    return true;
}

template<class T1, class T2, class T1RNG = fph::dynamic::RandomGenerator<T1>, class T2RNG = fph::dynamic::RandomGenerator<T2>>
class RandomPairGen {
public:
    RandomPairGen(): init_seed(std::random_device{}()), random_engine(init_seed), t1_gen(init_seed), t2_gen(init_seed) {}

    std::pair<T1,T2> operator()() {
        return {t1_gen(), t2_gen()};
    }

    template<class SeedType>
    void seed(SeedType seed) {
        random_engine.seed(seed);
        t1_gen.seed(seed);
        t2_gen.seed(seed);
    }

    size_t init_seed;

protected:
    std::mt19937_64 random_engine;
    T1RNG t1_gen;
    T2RNG t2_gen;
};



template<LookupExpectation LOOKUP_EXP, TableType table_type, bool verbose = true, class Table, class PairVec,
        class GetKey = SimpleGetKey<typename PairVec::value_type> >
std::tuple<uint64_t, uint64_t> TestTableLookUp(Table &table, size_t lookup_time, const PairVec &input_vec,
                                               const PairVec &lookup_vec, size_t seed,
                                               double max_load_factor = 0.9, double c = 2.0) {

    size_t look_up_index = 0;
    size_t key_num = input_vec.size();
    uint64_t useless_sum = 0;
    if (input_vec.empty()) {
        return {0, 0};
    }
    std::mt19937_64 random_engine(seed);
    std::uniform_int_distribution<size_t> random_dis;
    auto pair_vec = lookup_vec;

    if constexpr(table_type == DYNAMIC_FPH_TABLE || table_type == META_FPH_TABLE) {
        table.max_load_factor(max_load_factor);
    }
    ConstructTable<table_type, Table, PairVec, GetKey>(table, input_vec, random_dis(random_engine), c, true, false);
    std::shuffle(pair_vec.begin(), pair_vec.end(), random_engine);

    auto look_up_t0 = std::chrono::high_resolution_clock::now();
    for (size_t t = 0; t < lookup_time; ++t) {
        ++look_up_index;
        if FPH_UNLIKELY(look_up_index >= key_num) {
            look_up_index -= key_num;
        }
        if constexpr (LOOKUP_EXP == KEY_IN) {
            auto find_it = table.find(GetKey{}(pair_vec[look_up_index]));
            useless_sum += *reinterpret_cast<uint8_t*>(std::addressof(find_it->second));
        }
        else if constexpr (LOOKUP_EXP == KEY_NOT_IN) {
            auto find_it = table.find(GetKey{}(pair_vec[look_up_index]));
            if FPH_UNLIKELY(find_it != table.end()) {
                LogHelper::log(Error, "Find key %s in table %s",
                               ToString(GetKey{}(pair_vec[look_up_index])).c_str(),
                               GetTableName(table_type).c_str());
                return {0, 0};
            }
        }
        else {
            auto find_it = table.find(GetKey{}(pair_vec[look_up_index]));
            if (find_it != table.end()) {
                useless_sum += find_it->second;
            }
        }

    }
    auto look_up_t1 = std::chrono::high_resolution_clock::now();
    auto look_up_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(look_up_t1 - look_up_t0).count();
    if constexpr (verbose) {
        LogHelper::log(Info, "%s look up use %.3f ns per call, use_less sum: %lu",
                       GetTableName(table_type).c_str(), look_up_ns * 1.0 / lookup_time,
                       useless_sum);
    }
    return {look_up_ns, useless_sum};
}

template<TableType table_type, bool do_reserve = true, bool verbose = true, class Table, class PairVec,
        class GetKey = SimpleGetKey<typename PairVec::value_type>>
uint64_t TestTableConstruct(Table &table, const PairVec &pair_vec, size_t seed = 0, double c = 2.0,
                            double max_load_factor = 0.9,
                            size_t test_time = 0) {
    (void)test_time;
    table.clear();
    auto begin_time = std::chrono::high_resolution_clock::now();
    if constexpr (table_type == DYNAMIC_FPH_TABLE || table_type == META_FPH_TABLE) {
        table.max_load_factor(max_load_factor);
    }
    ConstructTable<table_type>(table, pair_vec, seed, c, do_reserve, true);
    auto end_time = std::chrono::high_resolution_clock::now();
    auto pass_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end_time - begin_time).count();
    if constexpr (verbose) {
        LogHelper::log(Info, "%s construct use time %.6f seconds",
                       GetTableName(table_type).c_str(), pass_ns / (1e+9));
    }
    return pass_ns;
}

template<TableType table_type, class Table, class PairVec,
        class GetKey = SimpleGetKey<typename PairVec::value_type> >
std::tuple<uint64_t, uint64_t> TestTableIterate(Table &table, size_t iterate_time, const PairVec &input_vec,
                                                size_t seed, double max_load_factor = 0.9, double c = 2.0) {
    if constexpr(table_type == DYNAMIC_FPH_TABLE || table_type == META_FPH_TABLE) {
        table.max_load_factor(max_load_factor);
    }
    ConstructTable<table_type, Table, PairVec, GetKey>(table, input_vec, seed, c);
    auto start_time = std::chrono::high_resolution_clock::now();
    uint64_t useless_sum = 0;
    for (size_t t = 0; t < iterate_time; ++t) {
        for (auto it = table.begin(); it != table.end(); ++it) {
            // TODO: if second is not int
            useless_sum += *reinterpret_cast<uint8_t*>(std::addressof(it->second));
        }
    }
    auto end_time = std::chrono::high_resolution_clock::now();
    uint64_t pass_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end_time - start_time).count();
    return {pass_ns, useless_sum};

}

template<typename T, typename = void>
struct MutableValue {
    using type = T;
};

template<typename T>
struct MutableValue<T, typename std::enable_if<is_pair<T>::value>::type> {
    using type = std::pair<typename std::remove_const<typename T::first_type>::type, typename T::second_type>;
};

template<TableType table_type, class ValueRandomGen, class Table, class value_type,
        class GetKey = SimpleGetKey<value_type>>
void TestTablePerformance(size_t element_num, size_t construct_time, size_t lookup_time,
                          size_t seed = 0, double c = 2.0, double max_load_factor = 0.9) {
    std::mt19937_64 random_engine(seed);
    std::uniform_int_distribution<size_t> size_gen;
//    using value_type = typename Table::value_type;
    using mutable_value_type = typename MutableValue<value_type>::type;

    using key_type = typename Table::key_type;
    ValueRandomGen value_gen{};
    value_gen.seed(seed);

    std::unordered_set<key_type> key_set;
    key_set.reserve(element_num);

    std::vector<mutable_value_type> src_vec;
    src_vec.reserve(element_num);
    for (size_t i = 0; i < element_num; ++i) {
        auto temp_pair = value_gen();
        if (key_set.find(GetKey{}(temp_pair)) != key_set.end()) {
            continue;
        }
        src_vec.push_back(temp_pair);
        key_set.insert(GetKey{}(temp_pair));
    }

    float print_load_factor = 0;

    size_t construct_seed = size_gen(random_engine);
    size_t total_reserve_construct_ns = 0;

    for (size_t t = 0; t < construct_time; ++t) {
        Table table;
        uint64_t temp_construct_ns = TestTableConstruct<table_type, true, false>
                (table, src_vec, construct_seed, c, max_load_factor);
        total_reserve_construct_ns += temp_construct_ns;
        print_load_factor = table.load_factor();
    }

    size_t total_no_reserve_construct_ns = 0;
    for (size_t t = 0; t < construct_time; ++t) {
        Table table;
        uint64_t temp_construct_ns = TestTableConstruct<table_type, false, false>
                (table, src_vec, construct_seed, c, max_load_factor);
        total_no_reserve_construct_ns += temp_construct_ns;
    }

    uint64_t in_lookup_ns = 0, useless_sum = 0;
    {
        Table table;
        std::tie(in_lookup_ns, useless_sum) = TestTableLookUp<KEY_IN, table_type, false, Table,
                std::vector<mutable_value_type>, GetKey>(table, lookup_time, src_vec,
                src_vec, construct_seed, max_load_factor, c);
    }


    std::vector<mutable_value_type> lookup_vec;
    lookup_vec.reserve(src_vec.size());
    for (size_t i = 0; i < src_vec.size(); ++i) {
        auto temp_pair = value_gen();

        while (key_set.find(GetKey{}(temp_pair)) != key_set.end()) {

            temp_pair = value_gen();
        }
        lookup_vec.push_back(temp_pair);
    }

    uint64_t out_lookup_ns = 0;
    {
        Table table;
        std::tie(out_lookup_ns, std::ignore) = TestTableLookUp<KEY_NOT_IN, table_type, false>(table, lookup_time, src_vec,
                                                                                              lookup_vec, construct_seed, max_load_factor, c);
    }

    uint64_t iterate_ns = 0, it_useless_sum = 0;
    uint64_t iterate_time = (lookup_time + element_num - 1) / element_num;
    {

        Table table;
        std::tie(iterate_ns, it_useless_sum) = TestTableIterate<table_type, Table,
                std::vector<mutable_value_type>, GetKey>(
                table, iterate_time, src_vec, construct_seed, max_load_factor, c);
    }

    LogHelper::log(Info, "%s %lu elements, sizeof(value_type)=%lu, load_factor: %.3f, construct with reserve avg use %.6f s,"
                         "construct without reserve avg use %.6f s, look up key in the table use %.3f ns per key,"
                         "look up key not in the table use %.3f ns per key, "
                         "iterate use %.3f ns per value, useless_sum: %lu",
                   GetTableName(table_type).c_str(), element_num, sizeof(value_type), print_load_factor,
                   total_reserve_construct_ns / (1e+9) / construct_time, total_no_reserve_construct_ns / (1e+9) / construct_time,
                   in_lookup_ns * 1.0 / lookup_time, out_lookup_ns * 1.0 / lookup_time,
                   iterate_ns * 1.0 / (iterate_time * element_num), useless_sum + it_useless_sum);




}



void TestSet() {
#if TEST_TABLE_CORRECT
    using KeyType = uint64_t;
//    using KeyType = uint64_t*;
//    using KeyType = std::string;
//    using KeyType = TestKeyClass;
//    using SeedHash = fph::SimpleSeedHash<KeyType>;
//    using SeedHash = TestKeySeedHash;
    using SeedHash = std::hash<KeyType>;
//    using SeedHash = fph::MixSeedHash<KeyType>;
//    using SeedHash = fph::StrongSeedHash<KeyType>;
//    using BucketParamType = uint32_t;

    using RandomKeyGenerator = fph::dynamic::RandomGenerator<KeyType>;
//    using RandomKeyGenerator = KeyClassRNG;

//    fph::DynamicFphSet<KeyType, SeedHash, std::equal_to<>,
//    std::allocator<KeyType>, BucketParamType, RandomKeyGenerator> dy_fph_set;

    using DyFphSet7bit = fph::DynamicFphSet<KeyType,  SeedHash, std::equal_to<>,
    std::allocator<KeyType>, uint8_t, RandomKeyGenerator>;
    using DyFphSet15bit = fph::DynamicFphSet<KeyType, SeedHash, std::equal_to<>,
    std::allocator<KeyType>, uint16_t, RandomKeyGenerator>;
    using DyFphSet31bit = fph::DynamicFphSet<KeyType, SeedHash, std::equal_to<>,
    std::allocator<KeyType>, uint32_t, RandomKeyGenerator>;

    using MetaFphSet7bit = fph::MetaFphSet<KeyType, SeedHash, std::equal_to<>,
            std::allocator<KeyType>, uint8_t>;
    using MetaFphSet15bit = fph::MetaFphSet<KeyType, SeedHash, std::equal_to<>,
            std::allocator<KeyType>, uint16_t>;
    using MetaFphSet31bit = fph::MetaFphSet<KeyType, SeedHash, std::equal_to<>,
            std::allocator<KeyType>, uint32_t>;

    //    using HashMethod = robin_hood::hash<KeyType>;
//    using HashMethod = absl::Hash<KeyType>;
//    using HashMethod = TestKeyHash;
    using HashMethod = std::hash<KeyType>;

    constexpr double TEST_CORR_MAX_LOAD_FACTOR = 0.7;


//    using BenchTable = absl::flat_hash_set<KeyType, HashMethod>;
    using BenchTable = std::unordered_set<KeyType, HashMethod>;


    {

        auto meta_max_load_factor_upper_limit = MetaFphSet7bit::max_load_factor_upper_limit();
        if (TestCorrectness<RandomKeyGenerator, MetaFphSet7bit , BenchTable>(128 * meta_max_load_factor_upper_limit,
                                                                             4000)) {
            LogHelper::log(Info, "Pass MetaFphSet7Bit test with %d keys", size_t(128 * meta_max_load_factor_upper_limit));
        }
        else {
            LogHelper::log(Error, "Fail in MetaFphSet7Bit test");
            return;
        }

        if (TestCorrectness<RandomKeyGenerator, MetaFphSet15bit, BenchTable>(3000,
                                                                             400)) {
            LogHelper::log(Info, "Pass MetaFphSet15Bit test with %d keys", 3000);
        }
        else {
            LogHelper::log(Error, "Fail in MetaFphSet15Bit test");
            return;
        }

        if (TestCorrectness<RandomKeyGenerator, MetaFphSet15bit, BenchTable>(65536 / 2 * TEST_CORR_MAX_LOAD_FACTOR,
                                                                             10)) {
            LogHelper::log(Info, "Pass MetaFphSet15Bit test with %d keys", size_t(65536 / 2 * TEST_CORR_MAX_LOAD_FACTOR));
        }
        else {
            LogHelper::log(Error, "Fail in MetaFphSet15Bit test");
            return;
        }
        if (TestCorrectness<RandomKeyGenerator, MetaFphSet31bit, BenchTable>(500000ULL,
                                                                             3)) {
            LogHelper::log(Info, "Pass MetaFphSet31Bit test with %d keys", 500000ULL);
        }
        else {
            LogHelper::log(Error, "Fail in MetaFphSet31Bit test");
            return;
        }

        auto max_load_factor_upper_limit = DyFphSet7bit::max_load_factor_upper_limit();
        if (TestCorrectness<RandomKeyGenerator, DyFphSet7bit, BenchTable>(128 * max_load_factor_upper_limit,
                                                                          4000)) {
            LogHelper::log(Info, "Pass DyFphSet7Bit test with %d keys", size_t(128 * max_load_factor_upper_limit));
        }
        else {
            LogHelper::log(Error, "Fail in DyFphSet7Bit test");
            return;
        }

        if (TestCorrectness<RandomKeyGenerator, DyFphSet15bit, BenchTable>(3000,
                                                                       400)) {
            LogHelper::log(Info, "Pass DyFphSet15Bit test with %d keys", 3000);
        }
        else {
            LogHelper::log(Error, "Fail in DyFphSet15Bit test");
            return;
        }

        if (TestCorrectness<RandomKeyGenerator, DyFphSet15bit, BenchTable>(65536 / 2 * TEST_CORR_MAX_LOAD_FACTOR,
                                                                       10)) {
            LogHelper::log(Info, "Pass DyFphSet15Bit test with %d keys", size_t(65536 / 2 * TEST_CORR_MAX_LOAD_FACTOR));
        }
        else {
            LogHelper::log(Error, "Fail in DyFphSet15Bit test");
            return;
        }

        if (TestCorrectness<RandomKeyGenerator, DyFphSet31bit, BenchTable>(500000ULL,
                                                                       3)) {
            LogHelper::log(Info, "Pass DyFphSet31Bit test with %d keys", 500000ULL);
        }
        else {
            LogHelper::log(Error, "Fail in DyFphSet31Bit test");
            return;
        }



    };
#endif

}

template<size_t size>
struct FixSizeStruct {
    constexpr FixSizeStruct()noexcept: data{0} {}
    char data[size];

    friend bool operator==(const FixSizeStruct<size>&a, const FixSizeStruct<size>&b) {
        return memcmp(a.data, b.data, size) == 0;
    }
};




void TestFPH() {
#if TEST_TABLE_CORRECT
    using KeyType = uint32_t;
//    using KeyType = TestKeyClass;
//    using KeyType = std::string;
//    using KeyType = const uint64_t*;
//    using KeyType = enum {
//        Type0,
//        Type1,
//        Type2,
//        Type3,
//    };
    using ValueType = uint64_t;
//    using ValueType = TestValueClass;
//    using ValueType = std::string;
//    using ValueType = FixSizeStruct<96>;
//    using BucketParamType = uint32_t;

//    using KeyRandomGen = KeyClassRNG;
    using KeyRandomGen = fph::dynamic::RandomGenerator<KeyType>;

    using ValueRandomGen = fph::dynamic::RandomGenerator<ValueType>;
//    using ValueRandomGen = ValueClassRNG;

    using RandomGenerator = RandomPairGen<KeyType, ValueType, KeyRandomGen , ValueRandomGen>;

    using SeedHash = std::hash<KeyType>;
//    using SeedHash = fph::SimpleSeedHash<KeyType>;
//    using SeedHash = fph::StrongSeedHash<KeyType>;
//    using SeedHash = fph::MixSeedHash<KeyType>;
//    using SeedHash = TestKeySeedHash;

    using DyFphMap7bit = fph::DynamicFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
    std::allocator<std::pair<const KeyType, ValueType>>, uint8_t, KeyRandomGen>;
    using DyFphMap15bit = fph::DynamicFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
    std::allocator<std::pair<const KeyType, ValueType>>, uint16_t, KeyRandomGen>;
    using DyFphMap31bit = fph::DynamicFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
    std::allocator<std::pair<const KeyType, ValueType>>, uint32_t, KeyRandomGen>;
//    using DyFphMap63bit = fph::DynamicFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
//    std::allocator<std::pair<const KeyType, ValueType>>, uint64_t, KeyRandomGen>;

    using MetaFphMap7bit = fph::MetaFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
            std::allocator<std::pair<const KeyType, ValueType>>, uint8_t>;
    using MetaFphMap15bit = fph::MetaFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
            std::allocator<std::pair<const KeyType, ValueType>>, uint16_t>;
    using MetaFphMap31bit = fph::MetaFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
            std::allocator<std::pair<const KeyType, ValueType>>, uint32_t>;

    static_assert(is_pair<typename DyFphMap7bit::value_type>::value);

//    using HashMethod = robin_hood::hash<KeyType>;
//    using HashMethod = absl::Hash<KeyType>;
    using HashMethod = std::hash<KeyType>;
//    using HashMethod = TestKeyHash;

//    using BenchTable = absl::flat_hash_map<KeyType, ValueType, HashMethod>;
    using BenchTable = std::unordered_map<KeyType, ValueType, HashMethod>;

    using StdHashTable = std::unordered_map<KeyType, ValueType, HashMethod>;
//    using AbslFlatTable = absl::flat_hash_map<KeyType, ValueType, HashMethod>;
//    using RobinFlatTable = robin_hood::unordered_flat_map<KeyType, ValueType, HashMethod>;
//    using SkaFlatTable = ska::flat_hash_map<KeyType, ValueType, HashMethod>;


    LogHelper::log(Debug, "sizeof DyFphMap15bit is %lu, sizeof MetaFphMap15bit is %lu, "
                          "sizeof StdHashTable is %lu",
                   sizeof(DyFphMap15bit), sizeof(MetaFphMap15bit), sizeof(StdHashTable));

//    absl::flat_hash_map<KeyType, ValueType, HashMethod> absl_map;
//    robin_hood::unordered_flat_map<KeyType, ValueType, HashMethod> robin_hood_map;

//    using PairType = std::pair<KeyType, ValueType>;
    constexpr double TEST_CORR_MAX_LOAD_FACTOR = 0.7;


    std::random_device random_device;
    std::uniform_int_distribution<size_t> random_gen;




    {
        auto max_load_factor_upper_limit = MetaFphMap7bit::max_load_factor_upper_limit();
        bool correct_test_ret;

        size_t test_element_up_bound = std::floor(128.0 * max_load_factor_upper_limit);
        correct_test_ret = TestCorrectness<RandomGenerator, MetaFphMap7bit, BenchTable>
                (test_element_up_bound, 4000);
        if (!correct_test_ret) {
            LogHelper::log(Error, "MetaFphMap7bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "MetaFphMap7bit Pass correctness test  with %lu max elements",
                           test_element_up_bound);
        }

        test_element_up_bound = 3000;
        correct_test_ret = TestCorrectness<RandomGenerator, MetaFphMap15bit, BenchTable>(test_element_up_bound, 400);
        if (!correct_test_ret) {
            LogHelper::log(Error, "MetaFphMap15bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "MetaFphMap15bit Pass correctness test  with %lu max elements",
                           test_element_up_bound);
        }

        test_element_up_bound = std::floor(65536.0 / 2.0 * TEST_CORR_MAX_LOAD_FACTOR);
        correct_test_ret = TestCorrectness<RandomGenerator, MetaFphMap15bit, BenchTable>(test_element_up_bound, 10);
        if (!correct_test_ret) {
            LogHelper::log(Error, "MetaFphMap15bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "MetaFphMap15bit Pass correctness test with %lu max elements",
                           test_element_up_bound);
        }

        test_element_up_bound = 500000ULL;
        correct_test_ret = TestCorrectness<RandomGenerator, MetaFphMap31bit, BenchTable>(test_element_up_bound, 1);
        if (!correct_test_ret) {
            LogHelper::log(Error, "MetaFphMap31bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "MetaFphMap31bit Pass correctness test with %lu max elements",
                           test_element_up_bound);
        }
    }
    {
        auto max_load_factor_upper_limit = DyFphMap7bit::max_load_factor_upper_limit();
        bool correct_test_ret;

        size_t test_element_up_bound = std::floor(128.0 * max_load_factor_upper_limit);
        correct_test_ret = TestCorrectness<RandomGenerator, DyFphMap7bit, BenchTable>
                (test_element_up_bound, 4000);
        if (!correct_test_ret) {
            LogHelper::log(Error, "DyFphMap7bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "DyFphMap7bit Pass correctness test  with %lu max elements",
                           test_element_up_bound);
        }

        test_element_up_bound = 3000;
        correct_test_ret = TestCorrectness<RandomGenerator, DyFphMap15bit, BenchTable>(test_element_up_bound, 400);
        if (!correct_test_ret) {
            LogHelper::log(Error, "DyFphMap15bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "DyFphMap15bit Pass correctness test  with %lu max elements",
                           test_element_up_bound);
        }

        test_element_up_bound = std::floor(65536.0 / 2.0 * TEST_CORR_MAX_LOAD_FACTOR);
        correct_test_ret = TestCorrectness<RandomGenerator, DyFphMap15bit, BenchTable>(test_element_up_bound, 10);
        if (!correct_test_ret) {
            LogHelper::log(Error, "DyFphMap15bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "DyFphMap15bit Pass correctness test with %lu max elements",
                           test_element_up_bound);
        }

        test_element_up_bound = 500000ULL;
        correct_test_ret = TestCorrectness<RandomGenerator, DyFphMap31bit, BenchTable>(test_element_up_bound, 1);
        if (!correct_test_ret) {
            LogHelper::log(Error, "DyFphMap31bit Fail to pass correct test with %lu max elements",
                           test_element_up_bound);
            return;
        } else {
            LogHelper::log(Info, "DyFphMap31bit Pass correctness test with %lu max elements",
                           test_element_up_bound);
        }
    }

#endif


}

void TestMapPerformance() {
    using KeyType = uint64_t;

//    using KeyType = TestKeyClass;
//    using KeyType = std::string;
    using ValueType = uint64_t;
//    using ValueType = TestValueClass;
//    using ValueType = std::string;
//    using ValueType = FixSizeStruct<96>;
    using BucketParamType = uint32_t;

    using KeyRandomGen = fph::dynamic::RandomGenerator<KeyType>;

    using ValueRandomGen = fph::dynamic::RandomGenerator<ValueType>;

    using RandomGenerator = RandomPairGen<KeyType, ValueType, KeyRandomGen , ValueRandomGen>;


//    using SeedHash = fph::SimpleSeedHash<KeyType>;
//    using SeedHash = fph::StrongSeedHash<KeyType>;
    using SeedHash = std::hash<KeyType>;
//    using SeedHash = fph::MixSeedHash<KeyType>;
//    using SeedHash = TestKeySeedHash;

    using Allocator = std::allocator<std::pair<const KeyType, ValueType>>;

    using PairType = std::pair<KeyType, ValueType>;
//    constexpr size_t KEY_NUM = 84100ULL;
    constexpr size_t KEY_NUM = 1'000'000ULL;
    constexpr size_t LOOKUP_TIME = 100000000ULL;
    constexpr size_t CONSTRUCT_TIME = 2;
    constexpr double TEST_MAX_LOAD_FACTOR = 0.6;

    constexpr double c = 2.0;

    using TestMetaFphMap = fph::MetaFphMap<KeyType, ValueType, SeedHash, std::equal_to<>, Allocator,
        BucketParamType>;

    using TestDyFphMap = fph::DynamicFphMap<KeyType, ValueType, SeedHash, std::equal_to<>,
            Allocator, BucketParamType, KeyRandomGen>;

//    using TestPerformanceMap = TestMetaFphMap;
//    using TestPerformanceMap = TestDyFphMap;

//    static_assert(is_pair<typename TestPerformanceMap::value_type>::value);




    using HashMethod = std::hash<KeyType>;
//    using HashMethod = TestKeyHash;


    using StdHashTable = std::unordered_map<KeyType, ValueType, HashMethod>;

    size_t performance_seed = std::random_device{}();

    TestTablePerformance<DYNAMIC_FPH_TABLE, RandomGenerator, TestDyFphMap, PairType>(KEY_NUM, CONSTRUCT_TIME, LOOKUP_TIME,
                                                                                                performance_seed, c, TEST_MAX_LOAD_FACTOR);
    TestTablePerformance<META_FPH_TABLE, RandomGenerator, TestMetaFphMap , PairType>(KEY_NUM, CONSTRUCT_TIME, LOOKUP_TIME,
                                                                                     performance_seed, c, TEST_MAX_LOAD_FACTOR);




    TestTablePerformance<STD_HASH_TABLE, RandomGenerator, StdHashTable, PairType>(KEY_NUM, CONSTRUCT_TIME, LOOKUP_TIME,
                                                                                  performance_seed, c, TEST_MAX_LOAD_FACTOR);
}
