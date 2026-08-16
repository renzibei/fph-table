cmake_minimum_required(VERSION 3.10)

project(fph_table_tests)

set(CMAKE_CXX_STANDARD 17)

set(MEMCHECK_FLAGS "-fsanitize=address -fno-omit-frame-pointer -fno-optimize-sibling-calls")
set(MEMCHECK_FLAGS "")

if(NOT MSVC)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wno-format-security ${MEMCHECK_FLAGS}")
endif()

# Registers the tests below with ctest. Without it `ctest` reports that no tests
# were found and exits successfully, so nothing would gate a build.
enable_testing()

# The benchmark is minutes long and cannot fail, so it is not part of the default
# ctest run. Turn this on to register it as well.
option(FPH_ENABLE_BENCHMARK_TEST "Register the performance benchmark as a ctest test" OFF)

add_executable(fph_table_tests main.cpp test_fph_table.cpp)

add_executable(sample_fph sample_fph.cpp)

add_executable(test_bits_array test_bits_array.cpp)

# Instantiates and exercises the public API of all four containers. The compile
# matrix builds this file with -Werror; here it is also run, which makes it a
# cheap smoke test that finishes in milliseconds.
add_executable(fph_api_smoke ci/compile_probe.cpp)

add_subdirectory(.. ${CMAKE_CURRENT_BINARY_DIR}/fph-table)

target_link_libraries(fph_table_tests fph::fph_table)
target_link_libraries(sample_fph fph::fph_table)
target_link_libraries(test_bits_array fph::fph_table)
target_link_libraries(fph_api_smoke fph::fph_table)

add_test(NAME fph_api_smoke COMMAND fph_api_smoke)
add_test(NAME bits_array COMMAND test_bits_array)
add_test(NAME sample_fph COMMAND sample_fph)
add_test(NAME fph_table_correctness COMMAND fph_table_tests --correctness)

# The randomized correctness suite is the long one; the others are seconds. All
# of them are silent about progress, hence the generous timeouts.
set_tests_properties(fph_api_smoke PROPERTIES LABELS correctness TIMEOUT 600)
set_tests_properties(bits_array PROPERTIES LABELS correctness TIMEOUT 600)
set_tests_properties(sample_fph PROPERTIES LABELS correctness TIMEOUT 600)
set_tests_properties(fph_table_correctness PROPERTIES LABELS "correctness;slow"
                     TIMEOUT 3600)

# The suite reports a failure through LogHelper and carries on; tests/main.cpp
# turns the count of those reports into the exit status, and also fails when too
# few checks ran, so a suite that returns without testing anything is a failure
# rather than a fast pass. The exit status is the verdict.
#
# Matching the escape sequence LogHelper emits for an Error is kept as a second,
# independent path to the same verdict, and covers sample_fph, which has no
# counter of its own. Not PASS_REGULAR_EXPRESSION: setting one makes ctest
# ignore the exit status, which would retire the check above.
set_tests_properties(fph_table_correctness sample_fph
                     PROPERTIES FAIL_REGULAR_EXPRESSION "\\[40;31m")

if(FPH_ENABLE_BENCHMARK_TEST)
    add_test(NAME fph_table_benchmark COMMAND fph_table_tests --benchmark)
    set_tests_properties(fph_table_benchmark PROPERTIES LABELS benchmark TIMEOUT 7200)
endif()
