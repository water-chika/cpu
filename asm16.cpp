#include <iostream>
#include <sstream>
#include <unordered_map>
#include <cstdint>
#include <format>
#include <string>
#include <vector>

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

int parse_arg(const std::string& str) {
    if (args.contains(str)) {
        return args[str];
    }
    else {
        return stoi(str);
    }
}

// Strip a '#' comment and return the remaining tokens of one source line.
std::vector<std::string> tokenize(const std::string& line) {
    auto code = line.substr(0, line.find('#'));
    auto stream = std::istringstream{code};
    auto tokens = std::vector<std::string>{};
    for (std::string token; stream >> token; ) {
        tokens.push_back(token);
    }
    return tokens;
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
    int line_number = 0;
    for (std::string line; std::getline(std::cin, line); ) {
        line_number++;
        auto tokens = tokenize(line);
        if (tokens.empty()) {
            continue;
        }
        if (tokens.size() != 4) {
            std::cerr << std::format("asm16: line {}: expected '<op> <arg0> <arg1> <arg2>', got {} token(s)\n",
                                     line_number, tokens.size());
            return 1;
        }
        const auto& opcode = tokens[0];
        const auto& arg0 = tokens[1];
        const auto& arg1 = tokens[2];
        const auto& arg2 = tokens[3];
        if (!opcodes.contains(opcode)) {
            std::cerr << std::format("asm16: line {}: unknown opcode '{}'\n", line_number, opcode);
            return 1;
        }
        if (enable_debug) {
            std::cerr << opcode << ',' << arg0 << ',' << arg1 << ',' << arg2 << std::endl;
        }
        uint8_t opcode_b = opcodes[opcode];
        int arg0_b, arg1_b, arg2_b;
        try {
            arg0_b = parse_arg(arg0);
            arg1_b = parse_arg(arg1);
            arg2_b = parse_arg(arg2);
        }
        catch (const std::exception&) {
            std::cerr << std::format("asm16: line {}: unknown argument in '{} {} {}'\n",
                                     line_number, arg0, arg1, arg2);
            return 1;
        }
        auto fits_in_3_bits = [&](const std::string& name, int value) {
            if (value < 0 || value > 7) {
                std::cerr << std::format("asm16: line {}: argument '{}' does not fit in 3 bits\n",
                                         line_number, name);
                return false;
            }
            return true;
        };
        if (!fits_in_3_bits(arg0, arg0_b) ||
            !fits_in_3_bits(arg1, arg1_b) ||
            !fits_in_3_bits(arg2, arg2_b)) {
            return 1;
        }
        uint16_t code = (opcode_b << 9) | (arg0_b << 6) | (arg1_b << 3) | arg2_b;
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
