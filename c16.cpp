// c16: a small C like compiler for the 16 bit CPU in this repository.
//
//   c16 [--asm | --hex | --bin] [--sep_with_line] < program.c16
//   c16 [options] --out-dir DIR file.c16 [file.c16 ...]
//
// With no file arguments it reads the source on stdin and writes to stdout,
// the way the assemblers next door do.  Given files it compiles each one
// independently into DIR, which is the shape a real build has: cpu16 holds
// 256 instruction words, so a program for it is a few dozen lines, and a
// large job is thousands of small files rather than one enormous one.
// Separate files share nothing, so with C16_BACKEND=threads they are
// compiled concurrently with no serial section at all - which scales far
// better than anything inside a single file can.  There are two output paths and they are the point of the
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
#include <string>
#include <string_view>
#include <vector>

namespace {

void report(const char* name, const c16_error& e) {
    if (e.line != 0) {
        std::fprintf(stderr, "c16: %s:%u: %s\n", name, e.line, e.message.c_str());
    }
    else {
        std::fprintf(stderr, "c16: %s: %s\n", name, e.message.c_str());
    }
}

// "src/thing.c16" plus ".list" becomes "<dir>/thing.list".
std::string output_path(const std::string& dir, const std::string& input,
                        const char* suffix) {
    size_t slash = input.find_last_of('/');
    std::string stem = slash == std::string::npos ? input : input.substr(slash + 1);
    size_t dot = stem.find_last_of('.');
    if (dot != std::string::npos && dot != 0) {
        stem = stem.substr(0, dot);
    }
    return dir.empty() ? stem + suffix : dir + "/" + stem + suffix;
}

}  // namespace

int main(int argc, const char* argv[]) {
    c16_options opt;
    opt.text = true;
    opt.hex = true;
    opt.sep_with_line = false;

    std::string out_dir;
    std::vector<std::string> inputs;

    for (int i = 1; i < argc; i++) {
        std::string_view a = argv[i];
        if (a == "--out-dir") {
            if (i + 1 >= argc) {
                std::fputs("c16: --out-dir needs a directory\n", stderr);
                return 2;
            }
            out_dir = argv[++i];
        }
        else if (a == "--asm") {
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
        else if (a == "--no-regalloc") {
            opt.registers_for_variables = false;
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
                       "  --no-regalloc     Keep every named variable in its frame byte\n"
                       "  --out-dir DIR     With file arguments, write the results into DIR\n"
                       "  --help            Show this help message\n"
                       "\nWith file arguments each file is compiled independently into\n"
                       "DIR (default: the current directory), as <name>.s or <name>.list.\n"
                       "C16_BACKEND=threads then compiles the files concurrently.\n", stdout);
            return 0;
        }
        else if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr, "c16: unknown option '%s'\n", argv[i]);
            return 2;
        }
        else {
            inputs.emplace_back(argv[i]);
        }
    }

    if (!inputs.empty()) {
        std::vector<c16_unit> units(inputs.size());
        size_t total = 0;
        for (size_t i = 0; i < inputs.size(); i++) {
            FILE* in = std::fopen(inputs[i].c_str(), "rb");
            if (in == nullptr) {
                std::fprintf(stderr, "c16: cannot open '%s'\n", inputs[i].c_str());
                return 1;
            }
            units[i].name = inputs[i];
            units[i].source = asm_read_all(in);
            std::fclose(in);
            total += units[i].source.size();
        }
        c16_backend_from_env(opt, total);
        c16_project_result built = c16_compile_all(units, opt);
        if (!built.ok) {
            for (size_t i = 0; i < units.size(); i++) {
                if (!built.units[i].ok) {
                    report(units[i].name.c_str(), built.units[i].error);
                }
            }
            return 1;
        }
        const char* suffix = opt.text ? ".s" : (opt.hex ? ".list" : ".bin");
        for (size_t i = 0; i < units.size(); i++) {
            std::string path = output_path(out_dir, units[i].name, suffix);
            FILE* out = std::fopen(path.c_str(), "wb");
            if (out == nullptr) {
                std::fprintf(stderr, "c16: cannot write '%s'\n", path.c_str());
                return 1;
            }
            const asm_array<uint8_t>& bytes = built.units[i].output;
            if (bytes.size() != 0) {
                std::fwrite(bytes.data(), 1, bytes.size(), out);
            }
            std::fclose(out);
        }
        return 0;
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
