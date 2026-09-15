// The gpu16 assembler.
//
// Same shape as asm.cpp and asm16.cpp: the ISA description lives in
// asm_kernel.hpp and the pipeline around it in asm_pipeline.hpp, so the
// serial, threaded and HIP backends all assemble gpu16 without any of them
// knowing that a third ISA exists.
//
// The command line matches the other two exactly - source on stdin, words on
// stdout, --hex, --debug, --sep_with_line - and the backend is chosen with
// ASM_BACKEND and ASM_THREADS in the environment.
//
// The ISA is docs/gpu_isa.md sections 4.1 to 4.13.  Every documented
// instruction assembles, including the vector, matrix, LDS and exec mask
// ones that gpu16.v cannot execute yet; those are held down by encoding
// tests instead of by simulation.

#include "asm_pipeline.hpp"

int main(int argc, const char* argv[]) {
    return asm_main<asm_gpu16>(argc, argv);
}
