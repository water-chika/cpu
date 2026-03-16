cmake_minimum_required(VERSION 3.20)

project(asm)

add_executable(asm asm.cpp)

target_compile_features(asm PUBLIC cxx_std_20)
