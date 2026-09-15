// The cpu16 assembler.  See asm.cpp: the two tools differ only in the ISA
// description they hand to the shared pipeline.

#include "asm_pipeline.hpp"

int main(int argc, const char* argv[]) {
    return asm_main<asm_cpu16>(argc, argv);
}
