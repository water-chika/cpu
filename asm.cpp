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
    {"sub", 5},
    {"neg", 6},
    {"mul", 7},
    {"div", 8},
    {"mov", 9},
    {"mov0", 10},
    {"imm", 11},
    {"shl", 12},
    {"shr", 13},

    {"condition_nz", 14},
    {"condition_z", 15},
    {"condition_lz", 16},
    {"condition_gz", 17},

    {"condition_1", 18},
    {"b", 18},
    {"set_b_target", 19},
    {"set_data_address", 20},

    {"ld", 24},
    {"st", 25},
    {"cl", 26},
    {"swap", 27},
    {"ld_p", 28},
    {"st_p", 29},

    {"set_src1_dst1", 31},
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
    {"condition_1", 0},
    {"b", 1},
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
        if (tokens.size() != 2) {
            std::cerr << std::format("asm: line {}: expected '<op> <arg>', got {} token(s)\n",
                                     line_number, tokens.size());
            return 1;
        }
        const auto& opcode = tokens[0];
        const auto& arg = tokens[1];
        if (!opcodes.contains(opcode)) {
            std::cerr << std::format("asm: line {}: unknown opcode '{}'\n", line_number, opcode);
            return 1;
        }
        if (enable_debug) {
            std::cerr << opcode << ',' << arg << std::endl;
        }
        uint8_t opcode_b = opcodes[opcode];
        int arg_b;
        try {
            arg_b = parse_arg(arg);
        }
        catch (const std::exception&) {
            std::cerr << std::format("asm: line {}: unknown argument '{}'\n", line_number, arg);
            return 1;
        }
        if (arg_b < 0 || arg_b > 7) {
            std::cerr << std::format("asm: line {}: argument '{}' does not fit in 3 bits\n",
                                     line_number, arg);
            return 1;
        }
        uint8_t code = (opcode_b << 3) | arg_b;
        if (enable_debug) {
            std::cerr << (int)opcode_b << ',' << (int)arg_b << std::endl;
        }
        if (output_hex) {
            std::cout << std::format("{:02x}", code);
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
