cmake_minimum_required(VERSION 3.10)

project(fph_table_tests)

set(CMAKE_CXX_STANDARD 17)

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wno-format-security")

add_executable(fph_table_tests main.cpp test_fph_table.cpp)

add_executable(sample_fph sample_fph.cpp)

add_subdirectory(.. ${CMAKE_CURRENT_BINARY_DIR}/fph-table)

target_link_libraries(fph_table_tests fph::fph_table)
target_link_libraries(sample_fph fph::fph_table)
