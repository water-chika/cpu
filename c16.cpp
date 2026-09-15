// c16: a small C like compiler for the 16 bit CPU in this repository.
//
//   c16 [--asm | --hex | --bin] [--sep_with_line] < program.c16
//
// It reads the source on stdin and writes to stdout, the way the assemblers
// next door do.  There are two output paths and they are the point of the
// tool:
//
//   --asm  the text path: cpu16 assembly, which "asm16" assembles unmodified.
//          This is what to read when something is wrong.
//   --hex  the binary path: machine words as hex text, produced by handing
//   --bin  each lowered instruction to the assembler's own encoder.  No
//          assembly text is ever formatted and nothing is lexed a second
//          time, so this is the fast one.  --bin writes raw little endian
//          words instead of hex digits.
//
// Both paths have to produce the same machine code; tests/run_c16_test.sh
// compiles every test program both ways and diffs the words.
//
// Backends come from the environment, as the assembler's do:
//
//   C16_BACKEND=serial|threads|hip|auto      C16_THREADS=<n>

#include "c16_pipeline.hpp"

#include <cstdio>
#include <string_view>
#include <vector>

int main(int argc, const char* argv[]) {
    c16_options opt;
    opt.text = true;
    opt.hex = true;
    opt.sep_with_line = false;

    for (int i = 1; i < argc; i++) {
        std::string_view a = argv[i];
        if (a == "--asm") {
            opt.text = true;
        }
        else if (a == "--hex") {
            opt.text = false;
            opt.hex = true;
        }
        else if (a == "--bin") {
            opt.text = false;
            opt.hex = false;
        }
        else if (a == "--sep_with_line") {
            opt.sep_with_line = true;
        }
        else if (a == "--help") {
            std::fputs("Usage: c16 [options] < program.c16\n"
                       "Options:\n"
                       "  --asm             Emit cpu16 assembly text (default)\n"
                       "  --hex             Emit machine words as hexadecimal text\n"
                       "  --bin             Emit machine words as raw little endian bytes\n"
                       "  --sep_with_line   With --hex, separate words with new lines\n"
                       "  --help            Show this help message\n", stdout);
            return 0;
        }
        else {
            std::fprintf(stderr, "c16: unknown option '%s'\n", argv[i]);
            return 2;
        }
    }

    std::vector<char> source = asm_read_all(stdin);
    c16_backend_from_env(opt, source.size());
    c16_result result = c16_compile(source, opt);
    if (!result.ok) {
        if (result.error.line != 0) {
            std::fprintf(stderr, "c16: line %u: %s\n", result.error.line,
                         result.error.message.c_str());
        }
        else {
            std::fprintf(stderr, "c16: %s\n", result.error.message.c_str());
        }
        return 1;
    }
    if (result.output.size() != 0) {
        std::fwrite(result.output.data(), 1, result.output.size(), stdout);
    }
    return 0;
}
