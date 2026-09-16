// The cpu_16_16_16_16 assembler.
//
// Same shape as asm.cpp, asm16.cpp and asm_gpu16.cpp: the ISA description
// lives in asm_kernel.hpp and the pipeline around it in asm_pipeline.hpp, so
// the serial, threaded and HIP backends all assemble this ISA without any of
// them knowing that a fourth one exists.
//
// The command line matches the other three exactly - source on stdin, words
// on stdout, --hex, --debug, --sep_with_line - and the backend is chosen
// with ASM_BACKEND and ASM_THREADS in the environment.
//
// The ISA is docs/cpu_16_16_16_16.md.  Its words are sixteen bits, like
// asm16's, but the encoding inside them is entirely different: two address
// instructions over sixteen registers, with six instruction formats.

#include "asm_pipeline.hpp"

int main(int argc, const char* argv[]) {
    return asm_main<asm_cpu_16_16_16_16>(argc, argv);
}
