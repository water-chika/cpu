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

// One source line that still has something to assemble, with the line number
// kept so that the second pass can report errors against the original file.
struct statement {
    int line_number;
    std::vector<std::string> tokens;
    int address;
};

// "la <dst> <label>" is the only pseudo instruction.  It loads the 8 bit
// address of a label into a register, which is what every branch needs
// because the branch target lives in a register.  The 8 bit CPU can only move
// a 3 bit immediate at a time and has no or-with-immediate, so the address is
// assembled a piece at a time through the src1/dst1 register, which acts as
// the scratch.  The expansion is always LA_WORDS instructions long, whatever
// the address is, so the first pass knows every label's address without
// having to resolve anything.
constexpr int LA_WORDS = 10;

bool is_label_definition(const std::string& token) {
    return token.size() > 1 && token.back() == ':';
}

int statement_size(const std::vector<std::string>& tokens) {
    return tokens[0] == "la" ? LA_WORDS : 1;
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
    // ---- pass one: read the whole program, record where every label lands
    auto program = std::vector<statement>{};
    auto labels = std::unordered_map<std::string, int>{};
    int line_number = 0;
    int address = 0;
    for (std::string line; std::getline(std::cin, line); ) {
        line_number++;
        auto tokens = tokenize(line);
        // A label definition is a token ending in ':'.  It may sit on a line
        // of its own or in front of an instruction.
        while (!tokens.empty() && is_label_definition(tokens[0])) {
            auto name = tokens[0].substr(0, tokens[0].size() - 1);
            if (labels.contains(name)) {
                std::cerr << std::format("asm: line {}: label '{}' defined twice\n",
                                         line_number, name);
                return 1;
            }
            labels[name] = address;
            tokens.erase(tokens.begin());
        }
        if (tokens.empty()) {
            continue;
        }
        if (address > 255) {
            std::cerr << std::format("asm: line {}: the program does not fit in 256 instructions\n",
                                     line_number);
            return 1;
        }
        program.push_back(statement{line_number, tokens, address});
        address += statement_size(tokens);
    }

    // ---- pass two: encode
    auto emit = [&](uint8_t code) {
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
    };
    auto encode = [&](const std::string& opcode, int arg_b) {
        emit(static_cast<uint8_t>((opcodes[opcode] << 3) | arg_b));
    };
    // Which register the program last handed to set_src1_dst1, or -1 if it
    // has not named one yet.  "la" needs it as a scratch.
    int scratch = -1;
    for (const auto& s : program) {
        line_number = s.line_number;
        const auto& opcode = s.tokens[0];

        if (opcode == "la") {
            if (s.tokens.size() != 3) {
                std::cerr << std::format("asm: line {}: expected 'la <dst> <label>', got {} token(s)\n",
                                         line_number, s.tokens.size());
                return 1;
            }
            const auto& dst = s.tokens[1];
            const auto& name = s.tokens[2];
            if (!(dst.size() == 2 && dst[0] == 'r' && dst[1] >= '0' && dst[1] <= '7')) {
                std::cerr << std::format("asm: line {}: 'la' destination '{}' is not a register\n",
                                         line_number, dst);
                return 1;
            }
            if (!labels.contains(name)) {
                std::cerr << std::format("asm: line {}: unknown label '{}'\n", line_number, name);
                return 1;
            }
            if (scratch < 0) {
                std::cerr << std::format("asm: line {}: 'la' needs a scratch register, "
                                         "put a 'set_src1_dst1' before it\n", line_number);
                return 1;
            }
            if (scratch == args[dst]) {
                std::cerr << std::format("asm: line {}: 'la' destination '{}' is also the "
                                         "src1/dst1 scratch register, pick another one\n",
                                         line_number, dst);
                return 1;
            }
            int target = labels[name];
            if (enable_debug) {
                std::cerr << std::format("la {} {} -> {}\n", dst, name, target);
            }
            // scratch = high 2 bits, shift it up, copy to dst, then fold in
            // the middle and low 3 bit groups the same way.
            encode("imm", (target >> 6) & 3);
            encode("shl", 3);
            encode("mov", args[dst]);
            encode("imm", (target >> 3) & 7);
            encode("or", args[dst]);
            encode("mov0", args[dst]);
            encode("shl", 3);
            encode("mov", args[dst]);
            encode("imm", target & 7);
            encode("or", args[dst]);
            continue;
        }

        if (s.tokens.size() != 2) {
            std::cerr << std::format("asm: line {}: expected '<op> <arg>', got {} token(s)\n",
                                     line_number, s.tokens.size());
            return 1;
        }
        const auto& arg = s.tokens[1];
        if (!opcodes.contains(opcode)) {
            std::cerr << std::format("asm: line {}: unknown opcode '{}'\n", line_number, opcode);
            return 1;
        }
        if (enable_debug) {
            std::cerr << opcode << ',' << arg << std::endl;
        }
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
        if (enable_debug) {
            std::cerr << (int)opcodes[opcode] << ',' << arg_b << std::endl;
        }
        if (opcode == "set_src1_dst1") {
            scratch = arg_b;
        }
        encode(opcode, arg_b);
    }
    return 0;
}
