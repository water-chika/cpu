// cpu16_sim: run a cpu16 program without any verilog.
//
//   cpu16_sim [--data file] [--cycles n] [--trace] program.list
//
// It reads the same hex word list the testbench reads and prints the final
// registers in the same format the .expect files use, one hex byte per line,
// r0 first.  That makes it directly diffable against what iverilog produced,
// which is the whole reason it exists: if the simulator and the RTL agree,
// the .expect file is confirmed by two independent implementations instead
// of asserted by one person.

#include "cpu16_sim.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

// The testbench's format: one hexadecimal number per line, blank lines and
// "//" comments ignored, exactly what $readmemh accepts here.
bool read_hex(const char* path, std::vector<unsigned long>& out) {
    FILE* f = std::fopen(path, "rb");
    if (f == nullptr) {
        std::fprintf(stderr, "cpu16_sim: cannot open '%s'\n", path);
        return false;
    }
    char line[256];
    while (std::fgets(line, sizeof(line), f) != nullptr) {
        char* p = line;
        while (*p == ' ' || *p == '\t') {
            p++;
        }
        if (*p == '\0' || *p == '\n' || *p == '\r' || (p[0] == '/' && p[1] == '/')) {
            continue;
        }
        out.push_back(std::strtoul(p, nullptr, 16));
    }
    std::fclose(f);
    return true;
}

}  // namespace

int main(int argc, char* argv[]) {
    const char* program_path = nullptr;
    const char* data_path = nullptr;
    uint64_t cycles = 1000000;
    bool show_data = false;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--data" && i + 1 < argc) {
            data_path = argv[++i];
        }
        else if (a == "--cycles" && i + 1 < argc) {
            cycles = std::strtoull(argv[++i], nullptr, 10);
        }
        else if (a == "--data-out") {
            show_data = true;
        }
        else if (a == "--help") {
            std::printf("Usage: cpu16_sim [--data file] [--cycles n] [--data-out] "
                        "program.list\n");
            return 0;
        }
        else if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr, "cpu16_sim: unknown option '%s'\n", argv[i]);
            return 2;
        }
        else {
            program_path = argv[i];
        }
    }
    if (program_path == nullptr) {
        std::fprintf(stderr, "cpu16_sim: no program given\n");
        return 2;
    }

    std::vector<unsigned long> words;
    if (!read_hex(program_path, words)) {
        return 1;
    }
    std::vector<uint16_t> program;
    program.reserve(words.size());
    for (unsigned long w : words) {
        program.push_back(static_cast<uint16_t>(w));
    }

    std::vector<uint8_t> data;
    if (data_path != nullptr) {
        std::vector<unsigned long> bytes;
        if (!read_hex(data_path, bytes)) {
            return 1;
        }
        for (unsigned long b : bytes) {
            data.push_back(static_cast<uint8_t>(b));
        }
    }

    cpu16_sim_result r = cpu16_simulate(program, data, cycles);
    if (!r.ok) {
        std::fprintf(stderr, "TEST FAIL: cpu16_sim: %s\n", r.error.c_str());
        return 1;
    }
    for (int i = 0; i < 8; i++) {
        std::printf("%02x\n", r.reg[i]);
    }
    if (show_data) {
        for (int i = 0; i < 256; i++) {
            std::printf("%02x%c", r.data[i], (i % 16) == 15 ? '\n' : ' ');
        }
    }
    return 0;
}
