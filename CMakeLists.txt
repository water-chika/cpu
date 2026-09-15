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

# The compiler is the same shape: a header only pipeline (c16_kernel.hpp,
# c16_compiler.hpp, c16_pipeline.hpp) that reuses the assembler's encoder, so
# it carries asm_core along with its own optional GPU backend.
add_library(c16_core INTERFACE)
target_link_libraries(c16_core INTERFACE asm_core)

# The ROCm/HIP backend is entirely optional.  Without hipcc the project still
# configures, builds and tests; the "hip" backend simply reports itself
# unavailable and the benchmark says so in its table.
include(CheckLanguage)
check_language(HIP)
if(CMAKE_HIP_COMPILER)
    enable_language(HIP)
    add_library(asm_hip STATIC asm_hip.hip)
    set_source_files_properties(asm_hip.hip PROPERTIES LANGUAGE HIP)
    target_include_directories(asm_hip PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_definitions(asm_hip PUBLIC ASM_HAVE_HIP)
    target_compile_options(asm_hip PRIVATE -Wall -Wextra)
    target_link_libraries(asm_core INTERFACE asm_hip)
    add_library(c16_hip STATIC c16_hip.hip)
    set_source_files_properties(c16_hip.hip PROPERTIES LANGUAGE HIP)
    target_include_directories(c16_hip PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_definitions(c16_hip PUBLIC C16_HAVE_HIP ASM_HAVE_HIP)
    target_compile_options(c16_hip PRIVATE -Wall -Wextra)
    target_link_libraries(c16_core INTERFACE c16_hip)
    message(STATUS "HIP found (${CMAKE_HIP_COMPILER}), building the GPU backends")
else()
    message(STATUS "HIP not found, building without the GPU backends")
endif()

add_executable(asm asm.cpp)
target_link_libraries(asm PRIVATE asm_core)

add_executable(asm16 asm16.cpp)
target_link_libraries(asm16 PRIVATE asm_core)

add_executable(asm_bench asm_bench.cpp)
target_link_libraries(asm_bench PRIVATE asm_core)

add_executable(c16 c16.cpp)
target_link_libraries(c16 PRIVATE c16_core)

add_executable(c16_bench c16_bench.cpp)
target_link_libraries(c16_bench PRIVATE c16_core)

add_executable(variables_to_registers variables_to_registers.cpp)
target_compile_features(variables_to_registers PUBLIC cxx_std_20)

# A human runs the benchmark with:
#
#   cmake --build build --target bench
#
# and gets the table for the 16 bit assembler.  "bench8" is the same for cpu8.
add_custom_target(bench
    COMMAND $<TARGET_FILE:asm_bench> --isa 16 --lines 2000000 --repeat 5
    DEPENDS asm_bench
    USES_TERMINAL
    COMMENT "benchmarking the cpu16 assembler across every available backend")
add_custom_target(bench8
    COMMAND $<TARGET_FILE:asm_bench> --isa 8 --lines 2000000 --repeat 5
    DEPENDS asm_bench
    USES_TERMINAL
    COMMENT "benchmarking the cpu8 assembler across every available backend")

# And the same for the compiler, which reports both of its output paths:
#
#   cmake --build build --target benchc
#
add_custom_target(benchc
    COMMAND $<TARGET_FILE:c16_bench> --functions 20000 --body 24 --repeat 5
    DEPENDS c16_bench
    USES_TERMINAL
    COMMENT "benchmarking the c16 compiler across every available backend")

# Simulation tests.  Each one assembles a program with the assembler built
# above, runs it on the verilog CPU under iverilog, and compares the final
# register values with a checked in expectation file.  Run them with:
#
#   cmake -S . -B build && cmake --build build && ctest --test-dir build
#
find_program(IVERILOG_EXECUTABLE iverilog)
find_program(VVP_EXECUTABLE vvp)

enable_testing()

# The backends have to agree byte for byte, on both ISAs and both output
# formats, or the parallel assembler is worthless.  These run whatever
# backends the machine has: with no GPU the hip column simply says so.
foreach(isa 8 16)
    foreach(format hex bin)
        add_test(
            NAME backends_cpu${isa}_${format}
            COMMAND asm_bench --isa ${isa} --lines 200000 --format ${format} --check
        )
        set_tests_properties(backends_cpu${isa}_${format}
                             PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
    endforeach()
endforeach()

# The compiler has the same obligation twice over: every backend of a path
# has to agree byte for byte, and the two paths have to agree with each
# other - the assembly the text path writes must assemble, with this
# repository's own asm16, to exactly the words the binary path emitted
# without ever formatting any text.  c16_bench --check proves both on a
# program far larger than any that fits on the real cpu16.
add_test(NAME backends_c16 COMMAND c16_bench --functions 4000 --body 24 --repeat 1 --check)
set_tests_properties(backends_c16 PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

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

    # The compiler's tests go one step further than the assembler's: they
    # compile the program down both output paths, diff the machine words, and
    # only then simulate.  A disagreement between the paths is a failure even
    # if the program would have run correctly.
    function(add_c16_test name program data expect cycles)
        if(data STREQUAL "-")
            set(data_arg "-")
        else()
            set(data_arg ${CMAKE_CURRENT_SOURCE_DIR}/${data})
        endif()
        add_test(
            NAME ${name}
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_c16_test.sh
                    $<TARGET_FILE:c16>
                    $<TARGET_FILE:asm16>
                    ${CMAKE_CURRENT_SOURCE_DIR}
                    test16.v
                    ${CMAKE_CURRENT_SOURCE_DIR}/${program}
                    ${data_arg}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/${expect}
                    ${cycles}
        )
        set_tests_properties(${name} PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
    endfunction()

    add_c16_test(c16_arith     tests/c16_arith.c16     -              c16_arith.expect       400)
    add_c16_test(c16_control   tests/c16_control.c16   -              c16_control.expect    6000)
    add_c16_test(c16_compare   tests/c16_compare.c16   -              c16_compare.expect    2000)
    add_c16_test(c16_functions tests/c16_functions.c16 -              c16_functions.expect  2000)
    add_c16_test(c16_spill     tests/c16_spill.c16     -              c16_spill.expect      2000)
    add_c16_test(c16_memory    tests/c16_memory.c16    tests/sum.data c16_memory.expect     4000)
    add_c16_test(c16_collatz   tests/c16_collatz.c16   -              c16_collatz.expect   40000)
else()
    message(WARNING "iverilog/vvp not found, the simulation tests are disabled")
endif()
