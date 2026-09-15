cmake_minimum_required(VERSION 3.20)

project(cpu CXX)

# Nothing here is a debugging target, and the benchmark is meaningless against
# an unoptimised build, so pick a sane default when the user did not choose.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "build type" FORCE)
endif()

find_package(Threads REQUIRED)

# The assembler is a header only pipeline (asm_kernel.hpp + asm_pipeline.hpp)
# with two thin front ends.  asm_core is what carries the include path, the
# language level, the warning flags and, when ROCm is installed, the GPU
# backend.
add_library(asm_core INTERFACE)
target_include_directories(asm_core INTERFACE ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(asm_core INTERFACE cxx_std_20)
target_link_libraries(asm_core INTERFACE Threads::Threads)
target_compile_options(asm_core INTERFACE -Wall -Wextra)

add_executable(asm asm.cpp)
target_link_libraries(asm PRIVATE asm_core)

add_executable(asm16 asm16.cpp)
target_link_libraries(asm16 PRIVATE asm_core)

add_executable(variables_to_registers variables_to_registers.cpp)
target_compile_features(variables_to_registers PUBLIC cxx_std_20)

# Simulation tests.  Each one assembles a program with the assembler built
# above, runs it on the verilog CPU under iverilog, and compares the final
# register values with a checked in expectation file.  Run them with:
#
#   cmake -S . -B build && cmake --build build && ctest --test-dir build
#
find_program(IVERILOG_EXECUTABLE iverilog)
find_program(VVP_EXECUTABLE vvp)

enable_testing()

if(IVERILOG_EXECUTABLE AND VVP_EXECUTABLE)
    function(add_cpu_test name assembler testbench program data expect cycles)
        if(data STREQUAL "-")
            set(data_arg "-")
        else()
            set(data_arg ${CMAKE_CURRENT_SOURCE_DIR}/${data})
        endif()
        add_test(
            NAME ${name}
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_test.sh
                    $<TARGET_FILE:${assembler}>
                    ${CMAKE_CURRENT_SOURCE_DIR}
                    ${testbench}
                    ${CMAKE_CURRENT_SOURCE_DIR}/${program}
                    ${data_arg}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/${expect}
                    ${cycles}
        )
        set_tests_properties(${name} PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
    endfunction()

    add_test(
        NAME verilog_lint
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/lint_verilog.sh ${CMAKE_CURRENT_SOURCE_DIR}
    )
    set_tests_properties(verilog_lint PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

    add_cpu_test(cpu8_sum    asm   test.v   tests/cpu8_sum.s    tests/sum.data cpu8_sum.expect    300)
    add_cpu_test(cpu8_sum_list asm test.v   cpu8_asm/sum.s      data.list      cpu8_sum_list.expect 300)
    add_cpu_test(cpu8_label  asm   test.v   tests/cpu8_label.s  -              cpu8_label.expect  200)
    add_cpu_test(cpu16_sum   asm16 test16.v tests/cpu16_sum.s   tests/sum.data cpu16_sum.expect   300)
    add_cpu_test(cpu16_count asm16 test16.v cpu16_asm/test.s    -              cpu16_count.expect 300)
    add_cpu_test(cpu16_label asm16 test16.v tests/cpu16_label.s -              cpu16_label.expect 200)
    add_cpu_test(cpu16_adc   asm16 test16.v tests/cpu16_adc.s   -              cpu16_adc.expect   100)
    add_cpu_test(cpu16_ldp   asm16 test16.v tests/cpu16_ldp.s   -              cpu16_ldp.expect   100)
else()
    message(WARNING "iverilog/vvp not found, the simulation tests are disabled")
endif()
