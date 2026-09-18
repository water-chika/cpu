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

add_executable(asm_gpu16 asm_gpu16.cpp)
target_link_libraries(asm_gpu16 PRIVATE asm_core)

add_executable(asm_16_16_16_16 asm_16_16_16_16.cpp)
target_link_libraries(asm_16_16_16_16 PRIVATE asm_core)

add_executable(asm_bench asm_bench.cpp)
target_link_libraries(asm_bench PRIVATE asm_core)

add_executable(c16 c16.cpp)
target_link_libraries(c16 PRIVATE c16_core)

# An independent implementation of the cpu16 instruction set, used to check
# the verilog and the compiler against each other rather than against a
# hand written expectation.
add_executable(cpu16_sim cpu16_sim.cpp)
target_compile_features(cpu16_sim PRIVATE cxx_std_20)
target_compile_options(cpu16_sim PRIVATE -Wall -Wextra)
target_include_directories(cpu16_sim PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(c16_verify c16_verify.cpp)
target_link_libraries(c16_verify PRIVATE c16_core)
target_compile_features(c16_verify PRIVATE cxx_std_20)
target_compile_options(c16_verify PRIVATE -Wall -Wextra)

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

# The backends have to agree byte for byte, on every ISA and both output
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

# And the same obligation for gpu16, whose --isa is 32 because the switch is
# named after the instruction word as 8 and 16 are.  This one is worth more
# than the other two: gpu16 is where the per line kernel got its typed
# operands, its variable operand count and its comma separated syntax, so if
# a backend is going to disagree with the others it will disagree here.
foreach(format hex bin)
    add_test(
        NAME backends_gpu16_${format}
        COMMAND asm_bench --isa 32 --lines 200000 --format ${format} --check
    )
    set_tests_properties(backends_gpu16_${format}
                         PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
endforeach()

# The fourth ISA, cpu_16_16_16_16.  Its words are sixteen bits like asm16's,
# but its statements are typed and comma separated like gpu16's, so it is the
# one combination the two blocks above do not already cover.
foreach(format hex bin)
    add_test(
        NAME backends_cpu_16_16_16_16_${format}
        COMMAND asm_bench --isa 1616 --lines 200000 --format ${format} --check
    )
    set_tests_properties(backends_cpu_16_16_16_16_${format}
                         PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
endforeach()

# The fourth ISA's assembler is tested on its own, without any simulator:
# what the encodings are, what the assembler refuses, and where the branch
# range ends.  The core's behaviour is tested separately, by simulation.
add_test(
    NAME cpu_16_16_16_16_encoding
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_encoding_test.sh
            $<TARGET_FILE:asm_16_16_16_16>
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/cpu_16_16_16_16_encoding.s
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/cpu_16_16_16_16_encoding.expect16
)
set_tests_properties(cpu_16_16_16_16_encoding
                     PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

add_test(
    NAME cpu_16_16_16_16_reject
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_reject_test.sh
            $<TARGET_FILE:asm_16_16_16_16>
            ${CMAKE_CURRENT_SOURCE_DIR}/tests/cpu_16_16_16_16_reject.cases
)
set_tests_properties(cpu_16_16_16_16_reject
                     PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

# ... and the same argument one level further back for that expectation
# file, which is generated from the document by a second encoder rather than
# written out by hand.  If someone ever "fixes" a failing encoding test by
# pasting in what the assembler printed, this is what notices.
find_package(Python3 COMPONENTS Interpreter)
if(Python3_Interpreter_FOUND)
    add_test(
        NAME cpu_16_16_16_16_encoding_expect
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_cpu_16_16_16_16_gen_check.sh
                ${Python3_EXECUTABLE}
                ${CMAKE_CURRENT_SOURCE_DIR}/tests
    )
    set_tests_properties(cpu_16_16_16_16_encoding_expect
                         PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
else()
    message(WARNING "python3 not found, the cpu_16_16_16_16 encoding expectation check is disabled")
endif()

# A range check is only worth anything if it is exact, so this assembles the
# furthest program that must work and the nearest one that must not, in both
# directions, for both branch formats.
add_test(
    NAME cpu_16_16_16_16_range
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_cpu_16_16_16_16_range.sh
            $<TARGET_FILE:asm_16_16_16_16>
)
set_tests_properties(cpu_16_16_16_16_range
                     PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

# The compiler has the same obligation twice over: every backend of a path
# has to agree byte for byte, and the two paths have to agree with each
# other - the assembly the text path writes must assemble, with this
# repository's own asm16, to exactly the words the binary path emitted
# without ever formatting any text.  c16_bench --check proves both on a
# program far larger than any that fits on the real cpu16.
add_test(NAME backends_c16 COMMAND c16_bench --functions 4000 --body 24 --repeat 1 --check)
set_tests_properties(backends_c16 PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

# Differential testing.  These need no verilog: they compare the compiler
# against a reference interpreter for the same language, and the encoder
# against itself down both output paths, using an independent model of the
# CPU to run the result.  A .expect file can only say that the whole stack
# agrees with its author; these say that three implementations that share no
# code agree with each other, which is a far stronger statement.
add_test(NAME c16_differential
         COMMAND c16_verify --fuzz 400 --seed 20260915 --functions 1 --statements 2)
set_tests_properties(c16_differential PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

# The same idea applied to programs with no calls at all, where almost every
# generated program fits the hardware, so the coverage per second is highest.
add_test(NAME c16_differential_flat
         COMMAND c16_verify --fuzz 400 --seed 31415926 --functions 0 --statements 3)
set_tests_properties(c16_differential_flat PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

# And over the checked in programs, so that the hand written .expect files
# are themselves confirmed by an implementation that never saw them.
foreach(prog c16_arith c16_compare c16_control c16_functions c16_spill c16_collatz
             c16_regalloc)
    add_test(NAME oracle_${prog}
             COMMAND c16_verify ${CMAKE_CURRENT_SOURCE_DIR}/tests/${prog}.c16)
    set_tests_properties(oracle_${prog} PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
endforeach()
add_test(NAME oracle_c16_memory
         COMMAND c16_verify --data ${CMAKE_CURRENT_SOURCE_DIR}/tests/sum.data
                 ${CMAKE_CURRENT_SOURCE_DIR}/tests/c16_memory.c16)
set_tests_properties(oracle_c16_memory PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

# Keeping a variable in a register is an optimisation, and an optimisation is
# only allowed to change the size of a program, never its answers.  The
# compiler still has --no-regalloc, which leaves every variable in its frame
# byte and is the code this suite trusted before the stage existed, so every
# program can be compiled both ways and the two runs compared.  The word
# counts printed by these tests are also the stage's only measurement.
function(add_regalloc_equivalence name program cycles outs)
    add_test(
        NAME regalloc_${name}
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_regalloc_equivalence.sh
                $<TARGET_FILE:c16>
                $<TARGET_FILE:cpu16_sim>
                ${CMAKE_CURRENT_SOURCE_DIR}/${program}
                ${cycles}
                ${outs}
    )
    set_tests_properties(regalloc_${name} PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
endfunction()

add_regalloc_equivalence(c16_arith     tests/c16_arith.c16       400 7)
add_regalloc_equivalence(c16_control   tests/c16_control.c16    6000 4)
add_regalloc_equivalence(c16_compare   tests/c16_compare.c16    2000 4)
add_regalloc_equivalence(c16_functions tests/c16_functions.c16  2000 4)
add_regalloc_equivalence(c16_spill     tests/c16_spill.c16      2000 2)
add_regalloc_equivalence(c16_collatz   tests/c16_collatz.c16   40000 2)
# tests/c16_regalloc.c16 is deliberately absent: it is 280 words with every
# variable in memory and 247 with the allocator, so the unallocated half of
# the comparison does not fit cpu16 at all.  Its answers are checked against
# the interpreter by oracle_c16_regalloc and against the RTL by c16_regalloc.

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
    add_cpu_test(cpu8_ldp    asm   test.v   tests/cpu8_ldp.s    -              cpu8_ldp.expect    100)
    add_cpu_test(cpu16_sum   asm16 test16.v tests/cpu16_sum.s   tests/sum.data cpu16_sum.expect   300)
    add_cpu_test(cpu16_count asm16 test16.v cpu16_asm/test.s    -              cpu16_count.expect 300)
    add_cpu_test(cpu16_label asm16 test16.v tests/cpu16_label.s -              cpu16_label.expect 200)
    add_cpu_test(cpu16_adc   asm16 test16.v tests/cpu16_adc.s   -              cpu16_adc.expect   100)
    add_cpu_test(cpu16_ldp   asm16 test16.v tests/cpu16_ldp.s   -              cpu16_ldp.expect   100)

    # cpu_16_16_16_16.  Each program is assembled by asm_16_16_16_16, has to
    # reach `halt` inside its cycle budget, and has to match all sixteen
    # registers - and, where the test stores anything, the data memory words
    # themselves through +mexpect.  Every expectation was computed from
    # docs/cpu_16_16_16_16.md by hand and none of it was read back from the
    # simulator; the numbers and the arithmetic behind them are written out
    # in the comments of each .s file.
    function(add_cpu_16_16_16_16_test name program data expect cycles)
        if(data STREQUAL "-")
            set(data_arg "-")
        else()
            set(data_arg ${CMAKE_CURRENT_SOURCE_DIR}/${data})
        endif()
        add_test(
            NAME ${name}
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_test_16_16_16_16.sh
                    $<TARGET_FILE:asm_16_16_16_16>
                    ${CMAKE_CURRENT_SOURCE_DIR}
                    ${CMAKE_CURRENT_SOURCE_DIR}/${program}
                    ${data_arg}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/${expect}
                    ${cycles}
                    ${ARGN}
        )
        set_tests_properties(${name} PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
    endfunction()

    add_cpu_16_16_16_16_test(cpu_16_16_16_16_alu
        tests/cpu_16_16_16_16_alu.s   - cpu_16_16_16_16_alu.expect   60)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_arith
        tests/cpu_16_16_16_16_arith.s - cpu_16_16_16_16_arith.expect 60)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_shift
        tests/cpu_16_16_16_16_shift.s - cpu_16_16_16_16_shift.expect 60)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_flags
        tests/cpu_16_16_16_16_flags.s - cpu_16_16_16_16_flags.expect 60)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_branch
        tests/cpu_16_16_16_16_branch.s - cpu_16_16_16_16_branch.expect 400)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_imm
        tests/cpu_16_16_16_16_imm.s   - cpu_16_16_16_16_imm.expect   60)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_jump
        tests/cpu_16_16_16_16_jump.s  - cpu_16_16_16_16_jump.expect  40)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_call
        tests/cpu_16_16_16_16_call.s  - cpu_16_16_16_16_call.expect  60)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_sys
        tests/cpu_16_16_16_16_sys.s   - cpu_16_16_16_16_sys.expect   60)

    # The two that store, and so check the memory array itself.
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_mem
        tests/cpu_16_16_16_16_mem.s tests/cpu_16_16_16_16_mem.data16
        cpu_16_16_16_16_mem.expect 60
        +mexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/cpu_16_16_16_16_mem.mexpect16
        +mexpect_words=15)
    add_cpu_16_16_16_16_test(cpu_16_16_16_16_sum
        tests/cpu_16_16_16_16_sum.s tests/cpu_16_16_16_16_sum.data16
        cpu_16_16_16_16_sum.expect 150
        +mexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/cpu_16_16_16_16_sum.mexpect16
        +mexpect_words=17)

    # The gpu16 scalar unit.  Each program is assembled by asm_gpu16 and then
    # has to reach s_endpgm and match all sixteen scalar registers.  The
    # expectation files were written against hand encoded hex before the
    # assembler existed, so a pass is a statement that the assembler and the
    # RTL read section 4.1 the same way.
    function(add_gpu_test name program data expect cycles)
        if(data STREQUAL "-")
            set(data_arg "-")
        else()
            set(data_arg ${CMAKE_CURRENT_SOURCE_DIR}/${data})
        endif()
        add_test(
            NAME ${name}
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_gpu_test.sh
                    $<TARGET_FILE:asm_gpu16>
                    ${CMAKE_CURRENT_SOURCE_DIR}
                    ${CMAKE_CURRENT_SOURCE_DIR}/${program}
                    ${data_arg}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests/${expect}
                    ${cycles}
                    ${ARGN}
        )
        set_tests_properties(${name} PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
    endfunction()

    add_gpu_test(gpu_alu    tests/gpu_alu.s        -  gpu_alu.expect    200
                 +arg_ptr=4096 +group_x=7 +group_y=9)
    add_gpu_test(gpu_imm    tests/gpu_imm.s    -  gpu_imm.expect    200)
    add_gpu_test(gpu_branch tests/gpu_branch.s -  gpu_branch.expect 300)
    add_gpu_test(gpu_sys    tests/gpu_sys.s    -  gpu_sys.expect    200
                 +wave_id=2 +group_x=5 +group_y=11)
    add_gpu_test(gpu_mem    tests/gpu_mem.s
                 tests/gpu_mem.data32 gpu_mem.expect 200)

    # The vector unit.  These pass a second expectation file, +vexpect, which
    # holds all 256 VGPRs - sixteen lanes of v0, then sixteen lanes of v1, and
    # so on - so a pass is a statement about every lane and not just about the
    # wave as a whole.  gpu_exec.s is the one that matters most: it is written
    # so that lane 0 is right whether or not the exec mask is obeyed, which is
    # exactly the bug a sixteen lane machine tested like a scalar one keeps.
    add_gpu_test(gpu_vector    tests/gpu_vector.s    - gpu_vector.expect    200
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_vector.vexpect)
    add_gpu_test(gpu_lane      tests/gpu_lane.s      - gpu_lane.expect      200
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_lane.vexpect)
    add_gpu_test(gpu_divergent tests/gpu_divergent.s - gpu_divergent.expect 300
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_divergent.vexpect)
    add_gpu_test(gpu_exec      tests/gpu_exec.s      - gpu_exec.expect      200
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_exec.vexpect)

    # Per lane global memory, sections 3.1 and 4.8.  gpu_global checks what
    # the loads bring back, gpu_gstore and gpu_gwide what the stores leave
    # behind and what the exec mask does to both, and gpu_coalesce checks the
    # thing values alone cannot see: how many 64 byte transactions the access
    # actually cost.  All four share one data file whose only rule is that the
    # byte at address a holds a & 0xff.
    add_gpu_test(gpu_global tests/gpu_global.s
                 tests/gpu_global.data32 gpu_global.expect 300
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_global.vexpect)

    add_gpu_test(gpu_gstore tests/gpu_gstore.s
                 tests/gpu_global.data32 gpu_gstore.expect 300
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_gstore.vexpect)

    add_gpu_test(gpu_gwide tests/gpu_gwide.s
                 tests/gpu_global.data32 gpu_gwide.expect 300
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_gwide.vexpect)

    add_gpu_test(gpu_coalesce tests/gpu_coalesce.s
                 tests/gpu_global.data32 gpu_coalesce.expect 300)

    # And the thing four KiB of on-chip memory could not do at all: address
    # two regions three quarters of a megabyte apart and get two different
    # answers back.  This is the test for the external global memory port
    # (docs/fpga_bringup.md 4.7); it fails by aliasing if the compute unit is
    # built with EXTERNAL_GMEM = 0 and its own 1024 word array.
    add_gpu_test(gpu_gfar tests/gpu_gfar.s - gpu_gfar.expect 300
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_gfar.vexpect)

    # The LDS, sections 3.2 and 4.9.  gpu_lds checks what the four access
    # instructions move, including the byte enables inside a bank word and
    # both halves of the exec rule; gpu_bank checks the thing values cannot
    # see, which is how many port cycles an access of a given bank pattern
    # costs - and in particular that section 3.2's 36 byte tile stride really
    # is conflict-free while the natural 32 byte one really does cost eight
    # times as much.  Neither needs a data file: the LDS has no initial
    # contents, so every word they read is a word they wrote.
    add_gpu_test(gpu_lds  tests/gpu_lds.s  - gpu_lds.expect  400
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_lds.vexpect)

    add_gpu_test(gpu_bank tests/gpu_bank.s - gpu_bank.expect 400)

    # The workgroup, sections 3.2, 3.3 and 7.2.  The only test that launches
    # more than one wave, and the only one that can say anything at all about
    # `s_barrier`, about the LDS and the global port being shared rather than
    # private, or about round-robin issue - all four are statements about
    # waves other than this one, and are unfalsifiable with a single wave.
    add_gpu_test(gpu_wg tests/gpu_wg.s - gpu_wg.expect 1500 +waves=4)

    # The matrix unit, sections 2.3 and 4.7 - the instruction the whole design
    # exists for, and the one where a wrong answer looks like a right one.
    # All of them share tests/gpu_mma.data32, and every expectation file is
    # computed by tests/gen_mma_expect.py from section 4.7's own loop rather
    # than captured from the simulator.
    #
    #   gpu_mma      acc_wr seeds a tile, two mma_i8 accumulate two K steps
    #                onto it, acc_rd reads all sixteen rows back;
    #   gpu_mma_z    acc_zero and mma_i8_z both erase a poisoned block, and
    #                the machine subtracts the two results itself;
    #   gpu_mma_sym  the symmetric control, which a transposed matrix unit
    #                still passes - it is here to make the next line mean
    #                something;
    #   gpu_mma_map  the same program with an asymmetric product, which pins
    #                the lane-to-row mapping and section 4.7's claim that the
    #                A fragment is the operand that crosses lanes;
    #   gpu_mma_exec section 4.7's sharp edge: disabled lanes keep their
    #                accumulators but still supply their A row;
    #   gpu_mma_perf the sixteen cycles, perf_mma_busy and the interlock,
    #                none of which any computed value can see;
    #   gpu_mma_wg   four waves queueing for one 64-MAC array, which is
    #                section 7.3's 4 x 256 arithmetic.
    add_gpu_test(gpu_mma tests/gpu_mma.s
                 tests/gpu_mma.data32 gpu_mma.expect 400
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_mma.vexpect)

    add_gpu_test(gpu_mma_z tests/gpu_mma_z.s
                 tests/gpu_mma.data32 gpu_mma_z.expect 600
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_mma_z.vexpect)

    add_gpu_test(gpu_mma_sym tests/gpu_mma_sym.s
                 tests/gpu_mma.data32 gpu_mma_sym.expect 300
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_mma_sym.vexpect)

    add_gpu_test(gpu_mma_map tests/gpu_mma_map.s
                 tests/gpu_mma.data32 gpu_mma_map.expect 300
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_mma_map.vexpect)

    add_gpu_test(gpu_mma_exec tests/gpu_mma_exec.s
                 tests/gpu_mma.data32 gpu_mma_exec.expect 400
                 +vexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_mma_exec.vexpect)

    add_gpu_test(gpu_mma_perf tests/gpu_mma_perf.s
                 tests/gpu_mma.data32 gpu_mma_perf.expect 400)

    add_gpu_test(gpu_mma_wg tests/gpu_mma_wg.s
                 tests/gpu_mma.data32 gpu_mma_wg.expect 2000 +waves=4)

    # gemm64, docs/gpu_isa.md section 7.1's smallest benchmark kernel, run for
    # real.  Everything above measures a piece of the machine; this is the
    # workload the machine exists for, and its answer is 4096 words of C
    # compared against a Python GEMM that shares no code with it.  The four
    # waves are not optional here: each one fills a quarter of the LDS tile,
    # so a single-wave run computes with three quarters of the tile undefined.
    add_gpu_test(gemm64 tests/gemm64.s
                 tests/gemm64.data32 gemm64.expect 30000 +waves=4
                 +mexpect=${CMAKE_CURRENT_SOURCE_DIR}/tests/gemm64.mexpect
                 +mexpect_word=2064 +mexpect_words=4096)

    # And the same run again, this time reading the counters the kernel
    # collected.  It is a separate test on purpose: the cycle count is only
    # meaningful if the matrix came out right, and this script refuses to
    # report one unless the same run passed the result comparison first.  The
    # band is section 7.4's, re-centred on the measurement now that there is
    # one; the tier-1 prediction it replaces is recorded in section 7.3.
    add_test(
        NAME gemm64_perf
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_gpu_perf.sh
                $<TARGET_FILE:asm_gpu16>
                ${CMAKE_CURRENT_SOURCE_DIR}
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/gemm64.s
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/gemm64.data32
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/gemm64.expect
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/gemm64.mexpect
                2064 4096 4 30000 5562 6798 4096
    )
    set_tests_properties(gemm64_perf PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

    # What the five tests above cannot reach.  gpu16.v is the scalar unit, so
    # simulation covers about a third of the ISA; the vector ALU, the matrix
    # unit, LDS and the exec mask are pinned by their encodings instead, which
    # needs no hardware at all.  The expectation file is derived from section
    # 4.2's field table and section 4.3 to 4.10's opcodes, and ends with
    # section 4.11's twelve worked encodings copied out of the prose.
    add_test(
        NAME gpu_encoding
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_encoding_test.sh
                $<TARGET_FILE:asm_gpu16>
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_encoding.s
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_encoding.expect32
    )
    set_tests_properties(gpu_encoding PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

    # An assembler that accepts nonsense is worse than one that is missing,
    # because the output is not something anyone reads back.  These are the
    # rules sections 4.1 to 4.10 state that no hardware enforces.
    add_test(
        NAME gpu_reject
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_reject_test.sh
                $<TARGET_FILE:asm_gpu16>
                ${CMAKE_CURRENT_SOURCE_DIR}/tests/gpu_reject.cases
    )
    set_tests_properties(gpu_reject PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

    # ... and the same argument one level further back for the matrix unit's
    # expectation files, which are generated rather than written.  An
    # expectation is only worth what its provenance is worth, so this re-runs
    # the generator and fails if a checked-in file has drifted from what the
    # ISA document says - which is what pasting in a simulator's output to
    # make a test pass would look like.
    find_package(Python3 COMPONENTS Interpreter)
    if(Python3_Interpreter_FOUND)
        add_test(
            NAME gpu_mma_expect
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_gen_check.sh
                    ${Python3_EXECUTABLE}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests
                    gen_mma_expect.py
        )
        set_tests_properties(gpu_mma_expect PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")

        # And the same for gemm64's input data and reference result, which are
        # a plain triple loop over the same integers the GPU is given.  The
        # kernel is checked against a multiply that shares no tiling, no
        # accumulator layout and no code with it.
        add_test(
            NAME gpu_gemm64_data
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_gen_check.sh
                    ${Python3_EXECUTABLE}
                    ${CMAKE_CURRENT_SOURCE_DIR}/tests
                    gen_gemm64.py
        )
        set_tests_properties(gpu_gemm64_data PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
    else()
        message(WARNING "python3 not found, the matrix expectation check is disabled")
    endif()

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
    add_c16_test(c16_regalloc  tests/c16_regalloc.c16  -              c16_regalloc.expect  14000)

    # Cross check the independent ISA simulator against the RTL.  Instead of
    # comparing the hardware with a number a human wrote down, this runs the
    # same program through cpu16_sim and makes its prediction for all eight
    # registers the expectation cpu16.v has to meet.  It covers every program
    # in the repository, assembly and compiled alike, so an ISA
    # misunderstanding on either side shows up as a disagreement rather than
    # as a test nobody wrote.
    function(add_cross_check name program data cycles)
        if(data STREQUAL "-")
            set(data_arg "-")
        else()
            set(data_arg ${CMAKE_CURRENT_SOURCE_DIR}/${data})
        endif()
        add_test(
            NAME xcheck_${name}
            COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_cross_check.sh
                    $<TARGET_FILE:asm16>
                    $<TARGET_FILE:c16>
                    $<TARGET_FILE:cpu16_sim>
                    ${CMAKE_CURRENT_SOURCE_DIR}
                    test16.v
                    ${CMAKE_CURRENT_SOURCE_DIR}/${program}
                    ${data_arg}
                    ${cycles}
        )
        set_tests_properties(xcheck_${name} PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
    endfunction()

    add_cross_check(cpu16_sum   tests/cpu16_sum.s       tests/sum.data   300)
    add_cross_check(cpu16_label tests/cpu16_label.s     -                200)
    add_cross_check(cpu16_adc   tests/cpu16_adc.s       -                100)
    add_cross_check(cpu16_ldp   tests/cpu16_ldp.s       -                100)
    add_cross_check(cpu16_count cpu16_asm/test.s        -                300)
    add_cross_check(c16_arith   tests/c16_arith.c16     -                400)
    add_cross_check(c16_control tests/c16_control.c16   -               6000)
    add_cross_check(c16_memory  tests/c16_memory.c16    tests/sum.data  4000)
    add_cross_check(c16_collatz tests/c16_collatz.c16   -              40000)
    add_cross_check(c16_regalloc tests/c16_regalloc.c16 -              14000)

    # The strongest check in the repository: random programs, compiled, run
    # on the actual verilog, and compared against what a reference
    # interpreter says the source language means.  No human wrote the
    # expectation and no human chose the program.
    add_test(
        NAME c16_fuzz_rtl
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/tests/run_fuzz_rtl.sh
                $<TARGET_FILE:c16_verify>
                $<TARGET_FILE:c16>
                ${CMAKE_CURRENT_SOURCE_DIR}
                test16.v
                24
                20260915
    )
    set_tests_properties(c16_fuzz_rtl PROPERTIES FAIL_REGULAR_EXPRESSION "TEST FAIL")
else()
    message(WARNING "iverilog/vvp not found, the simulation tests are disabled")
endif()
