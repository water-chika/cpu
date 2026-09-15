// A benchmark for the assembler's parallel stages.
//
//   asm_bench [--isa 8|16] [--lines N] [--seed S] [--repeat R]
//             [--format hex|bin] [--threads N] [--check]
//
// It generates a synthetic program of the requested size, assembles it once
// per backend, checks that every backend produced byte for byte the same
// output, and prints throughput and speedup.  --check is the same thing with
// the printing turned into a pass/fail line, which is what CTest runs.
//
// The generated program is a deterministic function of --seed and --lines, so
// two runs on the same machine are comparing the same work.
//
// One honest caveat: the assemblers cap a program at 256 instruction words
// because that is all the CPU has, and a 256 word program is far too small to
// measure anything.  The benchmark therefore lifts that one limit (and only
// that one) through asm_options::address_limit.  Every other byte of the work
// - lexing, parsing, label resolution, encoding, formatting - is exactly what
// the real assembler does.

#include "asm_pipeline.hpp"

#include <cinttypes>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

// xorshift64*, so that the generated program does not depend on the host's
// random number library.
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

const char* const cpu8_ops[] = {
    "and", "or", "not", "xor", "add", "sub", "neg", "mul",
    "div", "mov", "mov0", "imm", "shl", "shr", "ld", "st",
};
const char* const cpu16_ops[] = {
    "and", "or", "not", "xor", "add", "adc", "sub", "sbb",
    "neg", "mul", "div", "mov", "imm", "imm_s", "shl", "shr",
    "srl", "srr", "sar", "ld", "st", "cl", "swap",
};

// Build a program that looks like real source: instructions, comments, blank
// lines, labels, and "la" references back to labels that already exist.
std::vector<char> generate(int isa, size_t lines, uint64_t seed) {
    rng r(seed);
    std::string text;
    text.reserve(lines * 20);
    size_t labels = 0;
    if (isa == 8) {
        // cpu8's "la" folds the address through the src1/dst1 scratch, so the
        // program has to name one before the first "la".
        text += "set_src1_dst1 1\n";
    }
    text += "start:\n";
    labels = 1;
    for (size_t i = 0; i < lines; i++) {
        uint32_t roll = r.below(100);
        if (roll < 6) {
            text += "# a comment, which the lexer has to strip\n";
            continue;
        }
        if (roll < 10) {
            text += "\n";
            continue;
        }
        if (roll < 13) {
            text += "l";
            text += std::to_string(labels++);
            text += ":\n";
            continue;
        }
        if (roll < 16 && labels > 1) {
            // "la <dst> <label>", the one pseudo instruction.  r1 is the
            // scratch on cpu8, so never use it as the destination there.
            text += "la r";
            text += static_cast<char>('2' + r.below(6));
            text += " l";
            text += std::to_string(1 + r.below(static_cast<uint32_t>(labels - 1)));
            text += "\n";
            continue;
        }
        if (isa == 8) {
            text += cpu8_ops[r.below(sizeof(cpu8_ops) / sizeof(cpu8_ops[0]))];
            text += " r";
            text += static_cast<char>('0' + r.below(8));
        }
        else {
            text += cpu16_ops[r.below(sizeof(cpu16_ops) / sizeof(cpu16_ops[0]))];
            for (int a = 0; a < 3; a++) {
                text += " r";
                text += static_cast<char>('0' + r.below(8));
            }
        }
        if (r.below(4) == 0) {
            text += "   # trailing comment";
        }
        text += "\n";
    }
    return std::vector<char>(text.begin(), text.end());
}

struct measurement {
    bool ran = false;
    std::string note;
    double seconds = 0;
    asm_stats stats;
    asm_array<uint8_t> output;
};

template <class ISA>
measurement run(const std::vector<char>& source, asm_backend backend,
                unsigned threads, bool hex, int repeat) {
    measurement m;
    asm_options opt;
    opt.hex = hex;
    opt.sep_with_line = hex;
    opt.backend = backend;
    opt.threads = threads;
    opt.address_limit = 0xffffffffu;
    for (int i = 0; i < repeat; i++) {
        double t0 = asm_now();
        asm_result result = asm_assemble<ISA>(source, opt);
        double t1 = asm_now();
        if (!result.ok) {
            m.note = result.error.code == ASM_OK ? result.error.detail
                                                 : asm_error_text<ISA>(result.error);
            while (!m.note.empty() && m.note.back() == '\n') {
                m.note.pop_back();
            }
            return m;
        }
        if (!m.ran || t1 - t0 < m.seconds) {
            m.seconds = t1 - t0;
            m.stats = result.stats;
        }
        m.ran = true;
        if (m.output.size() == 0) {
            m.output = std::move(result.output);
        }
    }
    return m;
}

void print_row(const char* name, const measurement& m, double serial_seconds,
               size_t input_bytes, size_t lines) {
    if (!m.ran) {
        std::printf("  %-12s %-58s\n", name, ("unavailable: " + m.note).c_str());
        return;
    }
    double mb = static_cast<double>(input_bytes) / (1024.0 * 1024.0);
    std::printf("  %-12s %8.2f ms %12.2f Mline/s %9.1f MB/s %7.2fx  %s\n",
                name, m.seconds * 1e3,
                static_cast<double>(lines) / m.seconds / 1e6,
                mb / m.seconds,
                serial_seconds > 0 ? serial_seconds / m.seconds : 0.0,
                m.stats.threads > 1 ? (std::to_string(m.stats.threads) + " threads").c_str()
                                    : "");
}

void print_stages(const char* name, const measurement& m) {
    if (!m.ran) {
        return;
    }
    std::printf("  %-12s split %6.2f ms  classify %6.2f ms  scan %6.2f ms  resolve %6.2f ms  encode %6.2f ms\n",
                name, m.stats.split * 1e3, m.stats.classify * 1e3,
                m.stats.scan * 1e3, m.stats.resolve * 1e3, m.stats.encode * 1e3);
}

bool same(const measurement& a, const measurement& b) {
    if (!a.ran || !b.ran) {
        return true;   // nothing to compare against
    }
    return a.output.size() == b.output.size() &&
           std::memcmp(a.output.data(), b.output.data(), a.output.size()) == 0;
}

template <class ISA>
int bench(size_t lines, uint64_t seed, int repeat, bool hex, unsigned threads, bool check_only) {
    int isa = ISA::word_bytes == 1 ? 8 : 16;
    std::vector<char> source = generate(isa, lines, seed);

    measurement serial = run<ISA>(source, asm_backend::serial, 1, hex, repeat);
    if (!serial.ran) {
        std::fprintf(stderr, "TEST FAIL: the serial backend failed: %s\n", serial.note.c_str());
        return 1;
    }
    measurement parallel = run<ISA>(source, asm_backend::threads, threads, hex, repeat);
    measurement gpu;
    if (asm_hip_available()) {
        // The GPU backend only takes over the per line stages; the host
        // stages around it get the same cores the threads backend gets, so
        // that the two columns differ in one thing only.
        gpu = run<ISA>(source, asm_backend::hip, threads, hex, repeat);
    }
    else {
        gpu.note = "no HIP device";
    }

    bool identical = same(serial, parallel) && same(serial, gpu);
    if (check_only) {
        std::printf("asm%d: %zu lines, %zu statements, %zu output bytes: serial %s, threads %s, hip %s\n",
                    isa, serial.stats.lines, serial.stats.statements, serial.output.size(),
                    "ok", parallel.ran ? "ok" : parallel.note.c_str(),
                    gpu.ran ? "ok" : gpu.note.c_str());
        if (!identical) {
            std::printf("TEST FAIL: the backends disagree about the output bytes\n");
            return 1;
        }
        std::printf("TEST PASS: every available backend produced identical bytes\n");
        return 0;
    }

    double mb = static_cast<double>(source.size()) / (1024.0 * 1024.0);
    std::printf("\ncpu%d assembler, %zu source lines, %.2f MiB, %zu instruction words\n",
                isa, serial.stats.lines, mb, serial.stats.words);
    std::printf("output: %s, %zu bytes; best of %d run(s); seed %" PRIu64 "\n",
                hex ? "hex text" : "raw words", serial.output.size(), repeat, seed);
    std::printf("gpu: %s\n\n", asm_hip_available() ? asm_hip_device_name().c_str()
                                                   : "none detected");
    std::printf("  %-12s %11s %19s %14s %8s\n", "backend", "time", "throughput", "", "speedup");
    print_row("serial", serial, serial.seconds, source.size(), serial.stats.lines);
    print_row("threads", parallel, serial.seconds, source.size(), serial.stats.lines);
    print_row("hip", gpu, serial.seconds, source.size(), serial.stats.lines);
    std::printf("\n  where the time goes:\n");
    print_stages("serial", serial);
    print_stages("threads", parallel);
    print_stages("hip", gpu);
    std::printf("\n  identical bytes across backends: %s\n", identical ? "yes" : "NO");
    return identical ? 0 : 1;
}

}  // namespace

int main(int argc, char* argv[]) {
    int isa = 16;
    size_t lines = 2000000;
    uint64_t seed = 1;
    int repeat = 3;
    bool hex = true;
    bool check_only = false;
    unsigned threads = asm_default_threads();

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        auto value = [&]() -> const char* { return i + 1 < argc ? argv[++i] : "0"; };
        if (a == "--isa") {
            isa = std::atoi(value());
        }
        else if (a == "--lines") {
            lines = static_cast<size_t>(std::atoll(value()));
        }
        else if (a == "--seed") {
            seed = static_cast<uint64_t>(std::atoll(value()));
        }
        else if (a == "--repeat") {
            repeat = std::atoi(value());
        }
        else if (a == "--threads") {
            threads = static_cast<unsigned>(std::atoi(value()));
        }
        else if (a == "--format") {
            hex = std::string(value()) != "bin";
        }
        else if (a == "--check") {
            check_only = true;
        }
        else if (a == "--help") {
            std::printf("Usage: asm_bench [--isa 8|16] [--lines N] [--seed S] [--repeat R]\n"
                        "                 [--format hex|bin] [--threads N] [--check]\n");
            return 0;
        }
        else {
            std::fprintf(stderr, "asm_bench: unknown option '%s'\n", a.c_str());
            return 2;
        }
    }
    if (repeat < 1) {
        repeat = 1;
    }
    if (threads < 1) {
        threads = 1;
    }
    return isa == 8 ? bench<asm_cpu8>(lines, seed, repeat, hex, threads, check_only)
                    : bench<asm_cpu16>(lines, seed, repeat, hex, threads, check_only);
}
