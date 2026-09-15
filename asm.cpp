// The cpu8 assembler.
//
// Reads a program on stdin and writes the instruction words on stdout, either
// raw or as hex separated by commas or newlines.  All of the work is in
// asm_kernel.hpp (the per line stages, which are independent of each other
// and run on whichever backend was picked) and asm_pipeline.hpp (the driver
// and the one serial scan that places addresses and resolves labels).
//
// The command line is unchanged; the backend is chosen with ASM_BACKEND and
// ASM_THREADS in the environment, and every backend produces the same bytes.

#include "asm_pipeline.hpp"

int main(int argc, const char* argv[]) {
    return asm_main<asm_cpu8>(argc, argv);
}
