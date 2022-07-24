cmake_minimum_required(VERSION 3.10)
project(flash_perfect_hash)

if(NOT MSVC)
    SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra")
endif()

add_library(fph_table INTERFACE)

add_library(fph::fph_table ALIAS fph_table)


target_include_directories(fph_table INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")



