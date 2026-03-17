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
    {"sub", 5},
    {"neg", 6},
    {"mul", 7},
    {"div", 8},
    {"mov", 9},
    {"mov0", 10},
    {"imm", 11},
    {"shl", 12},
    {"shr", 13},

    {"bnz", 16},
    {"bz", 17},
    {"b", 18},
    {"blz", 19},
    {"bgz", 20},

    {"ld", 24},
    {"st", 25},
    {"cl", 26},
    {"swap", 27},
    {"ld_p", 28},
    {"st_p", 29},
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
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--hex") {
            output_hex = true;
        }
        else if (std::string(argv[i]) == "--debug") {
            enable_debug = true;
        }
    }
    while (true) {
        std::string opcode, arg;
        std::cin >> opcode >> arg;
        if (!std::cin.good()) {
           break;
        }
        if (enable_debug) {
            std::cerr << opcode << ',' << arg << std::endl;
        }
        uint8_t opcode_b = opcodes[opcode];
        uint8_t arg_b = parse_arg(arg);
        uint8_t code = (opcode_b << 3) | arg_b;
        if (enable_debug) {
            std::cerr << (int)opcode_b << ',' << (int)arg_b << std::endl;
        }
        if (output_hex) {
            std::cout << std::format("{:02x},", code);
        }
        else {
            std::cout.write(reinterpret_cast<char*>(&code), sizeof(code));
        }
    }
    return 0;
}
