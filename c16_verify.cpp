// c16_verify: check the compiler, the encoder and the CPU against each other.
//
//   c16_verify [--data file] program.c16          one program
//   c16_verify --fuzz N [--seed S] [--max-words W] random programs
//   c16_verify --rtl-out DIR --fuzz N             write programs and .expect
//                                                 files for the iverilog run
//
// The problem this solves: a checked in .expect file proves only that the
// whole stack agrees with whoever wrote the number.  If it disagrees, the
// compiler, the assembler and the verilog are all equally suspect, and if the
// author's arithmetic was wrong the test is wrong in a way that running it
// can never reveal.
//
// So each program is run through three independent implementations and the
// answers are compared pairwise.  Each comparison indicts exactly one
// component:
//
//   interpreter  vs  ISA simulator     the COMPILER's lowering
//   text path    vs  binary path       the ENCODER and the assembler
//   ISA simulator vs  cpu16.v          the RTL (done by tests/run_c16_test.sh
//                                      and tests/cross_check.sh)
//
// The interpreter evaluates the grammar and knows nothing about registers,
// spilling, the carry flag or instruction encoding.  The simulator executes
// instructions and knows nothing about the language.  They agree only when
// the compiler between them is right.
//
// --fuzz generates random programs, which is the part that finds bugs nobody
// thought to write a test for.  Every generated program terminates by
// construction: loops count a variable the body never touches.

#include "c16_interp.hpp"
#include "c16_pipeline.hpp"
#include "cpu16_sim.hpp"

#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct rng {
    uint64_t state;
    explicit rng(uint64_t seed) : state(seed == 0 ? 0x9e3779b97f4a7c15ull : seed) {}
    uint64_t next() {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        return state * 0x2545f4914f6cdd1dull;
    }
    uint32_t below(uint32_t n) { return static_cast<uint32_t>(next() % n); }
};

// ------------------------------------------------------- random programs

// Generating random source that is guaranteed valid is most of the work.
// The rules that keep it valid:
//
//   * a loop counts a variable that nothing in its body assigns, so every
//     program terminates,
//   * division is only ever by a non zero literal, because division by zero
//     is undefined on this hardware and so has no right answer to compare,
//   * shifts are only ever by a literal 0..7, which is what the ISA takes,
//   * function f(i) may only call f(j) for j < i, so the call graph is
//     acyclic and the fixed frames are safe,
//   * every variable is declared before it is used.
class generator {
public:
    generator(rng& r, uint32_t functions, uint32_t statements)
        : r_(r), functions_(functions), statements_(statements) {}

    std::string build() {
        std::string s;
        nglobals_ = r_.below(3);
        for (uint32_t i = 0; i < nglobals_; i++) {
            s += "int g" + std::to_string(i) + " = " + std::to_string(r_.below(200)) + ";\n";
        }
        for (uint32_t f = 0; f < functions_; f++) {
            current_ = f;
            s += function(f);
        }
        current_ = functions_;
        s += main_function();
        return s;
    }

private:
    std::string var() {
        // Anything currently in scope: a local, a parameter or a global.
        uint32_t n = static_cast<uint32_t>(locals_.size()) + nglobals_;
        if (n == 0) {
            return std::to_string(r_.below(256));
        }
        uint32_t pick = r_.below(n);
        if (pick < locals_.size()) {
            return locals_[pick];
        }
        return "g" + std::to_string(pick - locals_.size());
    }

    std::string expr(uint32_t depth) {
        if (depth == 0 || r_.below(100) < 25) {
            uint32_t roll = r_.below(100);
            if (roll < 45) {
                return var();
            }
            if (roll < 85) {
                return std::to_string(r_.below(256));
            }
            return "peek(" + std::to_string(r_.below(64)) + ")";
        }
        uint32_t roll = r_.below(100);
        if (roll < 10 && current_ > 0) {
            // A call to an earlier function, which is what exercises the
            // caller saved expression stack.
            uint32_t callee = r_.below(current_);
            return "f" + std::to_string(callee) + "(" + expr(depth - 1) + ", " +
                   expr(depth - 1) + ")";
        }
        if (roll < 18) {
            const char* un[] = {"-", "!", "~"};
            return std::string("(") + un[r_.below(3)] + "(" + expr(depth - 1) + "))";
        }
        if (roll < 26) {
            return "((" + expr(depth - 1) + ") / " + std::to_string(1 + r_.below(9)) + ")";
        }
        if (roll < 32) {
            const char* sh[] = {"<<", ">>"};
            return "((" + expr(depth - 1) + ") " + sh[r_.below(2)] + " " +
                   std::to_string(r_.below(8)) + ")";
        }
        if (roll < 52) {
            const char* rel[] = {"<", ">", "<=", ">=", "==", "!="};
            return "((" + expr(depth - 1) + ") " + rel[r_.below(6)] + " (" +
                   expr(depth - 1) + "))";
        }
        if (roll < 60) {
            const char* log[] = {"&&", "||"};
            return "((" + expr(depth - 1) + ") " + log[r_.below(2)] + " (" +
                   expr(depth - 1) + "))";
        }
        const char* bin[] = {"+", "-", "*", "&", "|", "^"};
        return "((" + expr(depth - 1) + ") " + bin[r_.below(6)] + " (" + expr(depth - 1) +
               "))";
    }

    std::string statement(const std::string& pad, uint32_t depth) {
        uint32_t roll = r_.below(100);
        if (roll < 22 && locals_.size() < 6) {
            std::string name = "v" + std::to_string(next_local_++);
            std::string s = pad + "int " + name + " = " + expr(2) + ";\n";
            locals_.push_back(name);
            return s;
        }
        if (roll < 34 && !locals_.empty()) {
            return pad + locals_[r_.below(static_cast<uint32_t>(locals_.size()))] + " = " +
                   expr(2) + ";\n";
        }
        if (roll < 46) {
            return pad + "poke(" + std::to_string(r_.below(64)) + ", " + expr(2) + ");\n";
        }
        if (roll < 62 && depth > 0) {
            std::string s = pad + "if (" + expr(2) + ") {\n";
            s += body(pad + "    ", 1 + r_.below(2), depth - 1);
            if (r_.below(2) == 0) {
                s += pad + "} else {\n";
                s += body(pad + "    ", 1 + r_.below(2), depth - 1);
            }
            s += pad + "}\n";
            return s;
        }
        if (roll < 74 && depth > 0) {
            // The counter is declared here and assigned only by the loop
            // itself, so the loop provably ends.
            std::string counter = "k" + std::to_string(next_local_++);
            std::string s = pad + "int " + counter + " = 0;\n";
            s += pad + "while (" + counter + " < " + std::to_string(1 + r_.below(6)) +
                 ") {\n";
            size_t before = locals_.size();
            s += body(pad + "    ", 1 + r_.below(2), depth - 1);
            if (r_.below(4) == 0) {
                s += pad + "    if (" + expr(1) + ") { break; }\n";
            }
            s += pad + "    " + counter + " = " + counter + " + 1;\n";
            s += pad + "}\n";
            locals_.resize(before);
            return s;
        }
        if (!locals_.empty()) {
            return pad + locals_[r_.below(static_cast<uint32_t>(locals_.size()))] + " = " +
                   expr(2) + ";\n";
        }
        return pad + "poke(" + std::to_string(r_.below(64)) + ", " + expr(1) + ");\n";
    }

    std::string body(const std::string& pad, uint32_t count, uint32_t depth) {
        std::string s;
        size_t before = locals_.size();
        for (uint32_t i = 0; i < count; i++) {
            s += statement(pad, depth);
        }
        locals_.resize(before);   // leaving the block forgets its declarations
        return s;
    }

    std::string function(uint32_t index) {
        locals_.clear();
        next_local_ = 0;
        locals_.push_back("a");
        locals_.push_back("b");
        std::string s = "int f" + std::to_string(index) + "(int a, int b) {\n";
        s += body("    ", statements_, 2);
        s += "    return " + expr(2) + ";\n}\n\n";
        locals_.clear();
        return s;
    }

    std::string main_function() {
        locals_.clear();
        next_local_ = 0;
        std::string s = "int main() {\n";
        s += body("    ", statements_, 2);
        uint32_t outs = 1 + r_.below(4);
        for (uint32_t i = 0; i < outs; i++) {
            s += "    out(" + std::to_string(i) + ", " + expr(2) + ");\n";
        }
        s += "    return 0;\n}\n";
        return s;
    }

    rng& r_;
    uint32_t functions_;
    uint32_t statements_;
    uint32_t current_ = 0;
    uint32_t nglobals_ = 0;
    uint32_t next_local_ = 0;
    std::vector<std::string> locals_;
};

// ------------------------------------------------------------ comparing

struct verdict {
    bool ok = false;
    bool skipped = false;    // too big for the real cpu16, not a failure
    std::string blame;       // which component, and why
};

verdict check_one(const std::vector<char>& source, const std::vector<uint8_t>& data,
                  bool verbose) {
    verdict v;

    // 1. the oracle: evaluate the language directly.
    c16_interp_result want = c16_interpret(source, data);
    if (!want.ok) {
        v.skipped = true;
        v.blame = "the interpreter could not run it: " + want.error;
        return v;
    }

    // 2. the binary path: lower straight to machine words.
    c16_options opt;
    opt.text = false;
    opt.hex = true;
    opt.sep_with_line = true;
    opt.backend = c16_backend::serial;
    opt.threads = 1;
    c16_result binary = c16_compile(source, opt);
    if (!binary.ok) {
        // Outgrowing the hardware is a property of the generated program,
        // not a defect, and it is the only error that is allowed to pass.
        if (binary.error.message.find("has room for") != std::string::npos) {
            v.skipped = true;
            return v;
        }
        v.blame = "the compiler rejected the program: " + binary.error.message;
        return v;
    }

    // 3. the text path, assembled by this repository's own asm16.
    c16_options text_opt = opt;
    text_opt.text = true;
    c16_result text = c16_compile(source, text_opt);
    if (!text.ok) {
        v.blame = "the text path rejected a program the binary path accepted: " +
                  text.error.message;
        return v;
    }
    {
        std::vector<char> asm_source(
            reinterpret_cast<const char*>(text.output.data()),
            reinterpret_cast<const char*>(text.output.data()) + text.output.size());
        asm_options ao;
        ao.hex = true;
        ao.sep_with_line = true;
        asm_result assembled = asm_assemble<asm_cpu16>(asm_source, ao);
        if (!assembled.ok) {
            v.blame = "ENCODER: asm16 rejected the compiler's own assembly: " +
                      asm_error_text<asm_cpu16>(assembled.error);
            return v;
        }
        if (assembled.output.size() != binary.output.size() ||
            std::memcmp(assembled.output.data(), binary.output.data(),
                        assembled.output.size()) != 0) {
            v.blame = "ENCODER: the text path and the binary path produced different words";
            return v;
        }
    }

    // 4. run the words on the independent ISA simulator.
    std::vector<uint16_t> words;
    {
        const char* p = reinterpret_cast<const char*>(binary.output.data());
        const char* end = p + binary.output.size();
        while (p < end) {
            words.push_back(static_cast<uint16_t>(std::strtoul(p, nullptr, 16)));
            while (p < end && *p != '\n') {
                p++;
            }
            p++;
        }
    }
    cpu16_sim_result got = cpu16_simulate(words, data, 2000000);
    if (!got.ok) {
        v.blame = "COMPILER: the compiled program " + got.error;
        return v;
    }

    // 5. the comparison that indicts the compiler.
    for (int i = 0; i < 7; i++) {
        if ((want.out_mask & (1u << i)) == 0) {
            continue;
        }
        if (got.reg[i] != want.out[i]) {
            char buf[256];
            std::snprintf(buf, sizeof(buf),
                          "COMPILER: out(%d) should be %u but the compiled program "
                          "left r%d holding %u",
                          i, want.out[i], i, got.reg[i]);
            v.blame = buf;
            return v;
        }
    }
    if (verbose) {
        std::printf("  %zu words, %" PRIu64 " cycles, out mask %02x, all agreed\n",
                    words.size(), got.cycles, want.out_mask);
    }
    v.ok = true;
    return v;
}

std::vector<char> to_vector(const std::string& s) {
    return std::vector<char>(s.begin(), s.end());
}

std::vector<uint8_t> read_data(const char* path) {
    std::vector<uint8_t> data;
    FILE* f = std::fopen(path, "rb");
    if (f == nullptr) {
        return data;
    }
    char line[128];
    while (std::fgets(line, sizeof(line), f) != nullptr) {
        char* p = line;
        while (*p == ' ' || *p == '\t') {
            p++;
        }
        if (*p == '\n' || *p == '\r' || *p == '\0') {
            continue;
        }
        data.push_back(static_cast<uint8_t>(std::strtoul(p, nullptr, 16)));
    }
    std::fclose(f);
    return data;
}

}  // namespace

int main(int argc, char* argv[]) {
    const char* program_path = nullptr;
    const char* data_path = nullptr;
    const char* rtl_out = nullptr;
    uint32_t fuzz = 0;
    uint64_t seed = 1;
    uint32_t functions = 1;
    uint32_t statements = 2;
    bool verbose = false;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto value = [&]() -> const char* { return i + 1 < argc ? argv[++i] : "0"; };
        if (a == "--data") {
            data_path = value();
        }
        else if (a == "--fuzz") {
            fuzz = static_cast<uint32_t>(std::atoi(value()));
        }
        else if (a == "--seed") {
            seed = static_cast<uint64_t>(std::atoll(value()));
        }
        else if (a == "--functions") {
            functions = static_cast<uint32_t>(std::atoi(value()));
        }
        else if (a == "--statements") {
            statements = static_cast<uint32_t>(std::atoi(value()));
        }
        else if (a == "--rtl-out") {
            rtl_out = value();
        }
        else if (a == "--verbose") {
            verbose = true;
        }
        else if (a == "--help") {
            std::printf("Usage: c16_verify [--data f] program.c16\n"
                        "       c16_verify --fuzz N [--seed S] [--functions F]\n"
                        "                  [--statements S] [--rtl-out DIR] [--verbose]\n");
            return 0;
        }
        else if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr, "c16_verify: unknown option '%s'\n", argv[i]);
            return 2;
        }
        else {
            program_path = argv[i];
        }
    }

    std::vector<uint8_t> data;
    if (data_path != nullptr) {
        data = read_data(data_path);
    }

    if (fuzz == 0) {
        if (program_path == nullptr) {
            std::fprintf(stderr, "c16_verify: no program and no --fuzz\n");
            return 2;
        }
        FILE* f = std::fopen(program_path, "rb");
        if (f == nullptr) {
            std::fprintf(stderr, "c16_verify: cannot open '%s'\n", program_path);
            return 1;
        }
        std::vector<char> source = asm_read_all(f);
        std::fclose(f);
        verdict v = check_one(source, data, true);
        if (v.skipped) {
            std::printf("skipped: %s\n", v.blame.c_str());
            return 0;
        }
        if (!v.ok) {
            std::printf("TEST FAIL: %s: %s\n", program_path, v.blame.c_str());
            return 1;
        }
        std::printf("TEST PASS: %s: the interpreter and the compiled program agree\n",
                    program_path);
        return 0;
    }

    rng r(seed);
    uint32_t checked = 0;
    uint32_t skipped = 0;
    uint32_t written = 0;
    for (uint32_t i = 0; i < fuzz; i++) {
        generator g(r, functions, statements);
        std::string text = g.build();
        std::vector<char> source = to_vector(text);
        verdict v = check_one(source, data, false);
        if (v.skipped) {
            skipped++;
            if (!v.blame.empty() && verbose) {
                std::printf("  program %u skipped: %s\n", i, v.blame.c_str());
            }
            continue;
        }
        if (!v.ok) {
            std::printf("TEST FAIL: generated program %u (seed %" PRIu64 "): %s\n", i, seed,
                        v.blame.c_str());
            std::printf("----- the program -----\n%s-----------------------\n", text.c_str());
            return 1;
        }
        checked++;

        // Optionally keep the program and the answer the interpreter
        // predicted, so the same check can be repeated against the real
        // verilog rather than against the ISA simulator.
        if (rtl_out != nullptr && written < 64) {
            c16_interp_result want = c16_interpret(source, data);
            std::string base = std::string(rtl_out) + "/fuzz" + std::to_string(written);
            FILE* src = std::fopen((base + ".c16").c_str(), "wb");
            if (src != nullptr) {
                std::fwrite(text.data(), 1, text.size(), src);
                std::fclose(src);
            }
            FILE* exp = std::fopen((base + ".expect").c_str(), "wb");
            if (exp != nullptr) {
                for (int k = 0; k < 8; k++) {
                    if (k < 7 && (want.out_mask & (1u << k)) != 0) {
                        std::fprintf(exp, "%02x\n", want.out[k]);
                    }
                    else {
                        std::fprintf(exp, "xx\n");
                    }
                }
                std::fclose(exp);
            }
            written++;
        }
    }
    std::printf("c16_verify: %u programs agreed, %u too big for cpu16 and skipped\n",
                checked, skipped);
    if (checked == 0) {
        std::printf("TEST FAIL: nothing was actually checked\n");
        return 1;
    }
    if (rtl_out != nullptr) {
        std::printf("wrote %u programs and their expected answers into %s\n", written,
                    rtl_out);
    }
    std::printf("TEST PASS: the interpreter, the encoder and the CPU model all agree\n");
    return 0;
}
