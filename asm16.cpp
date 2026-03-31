#include <iostream>
#include <unordered_map>
#include <cstdint>
#include <format>
#include <string>

auto opcodes = std::unordered_map<std::string, uint8_t>{
    {"and", 0},
    {"or", 1},
    {"not", 2},
    {"xor", 3},
    {"add", 4},
    {"adc", 5},
    {"sub", 6},
    {"sbb", 7},
    {"neg", 8},
    {"mul", 9},
    {"div", 10},
    {"mov", 11},
    {"imm", 12},
    {"imm_s", 13},
    {"shl", 14},
    {"shr", 15},
    {"srl", 16},
    {"srr", 17},
    {"sar", 18},
    {"add_ip", 19},

    {"bnz", 32},
    {"bz", 33},
    {"b", 34},
    {"blz", 35},
    {"bgz", 36},

    {"ld", 64},
    {"st", 65},
    {"cl", 66},
    {"swap", 67},
    {"ld_p", 68},
    {"st_p", 69},
};

auto args = std::unordered_map<std::string, uint8_t>{
    {"r0", 0},
    {"r1", 1},
    {"r2", 2},
    {"r3", 3},
    {"r4", 4},
    {"r5", 5},
    {"r6", 6},
    {"r7", 7},
};

uint8_t parse_arg(const std::string& str) {
    if (args.contains(str)) {
        return args[str];
    }
    else {
        return stoi(str);
    }
}

int main(int argc, const char* argv[]) {
    bool output_hex = false;
    bool enable_debug = false;
    bool sep_with_line = false;
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--hex") {
            output_hex = true;
        }
        else if (std::string(argv[i]) == "--debug") {
            enable_debug = true;
        }
        else if (std::string(argv[i]) == "--sep_with_line") {
            sep_with_line = true;
        }
        else if (std::string(argv[i]) == "--help") {
            std::cout << "Usage: asm [options]\n"
                         "Options:\n"
                         "  --hex             Output in hexadecimal format\n"
                         "  --debug           Enable debug output\n"
                         "  --sep_with_line   Separate output with new lines instead of commas\n"
                         "  --help            Show this help message\n";
            return 0;
        }
    }
    while (true) {
        std::string opcode, arg0, arg1, arg2;
        std::cin >> opcode >> arg0 >> arg1 >> arg2;
        if (!std::cin.good()) {
           break;
        }
        if (enable_debug) {
            std::cerr << opcode << ',' << arg0 << ',' << arg1 << ',' << arg2 << std::endl;
        }
        uint8_t opcode_b = opcodes[opcode];
        uint8_t arg0_b = parse_arg(arg0);
        uint8_t arg1_b = parse_arg(arg1);
        uint8_t arg2_b = parse_arg(arg2);
        uint16_t code = (opcode_b << 9) | (arg0_b << 6) | (arg1_b << 3) | arg0_b;
        if (enable_debug) {
            std::cerr << (int)opcode_b << ',' << (int)arg0_b << ',' << (int)arg1_b << ',' << (int)arg2_b << std::endl;
        }
        if (output_hex) {
            std::cout << std::format("{:04x}", code);
            if (sep_with_line) {
                std::cout << std::endl;
            } else {
                std::cout << ',';
            }
        }
        else {
            std::cout.write(reinterpret_cast<char*>(&code), sizeof(code));
        }
    }
    return 0;
}
