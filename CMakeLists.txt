cmake_minimum_required(VERSION 3.20)

project(asm)

add_executable(asm asm.cpp)

target_compile_features(asm PUBLIC cxx_std_20)

add_executable(variables_to_registers variables_to_registers.cpp)
target_compile_features(variables_to_registers PUBLIC cxx_std_20)

add_executable(asm16 asm16.cpp)

target_compile_features(asm16 PUBLIC cxx_std_20)
