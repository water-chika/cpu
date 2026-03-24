// input: op v0 v1 v2
// meaning: v0 op v1 -> v2

#include <iostream>
#include <variant>
#include <cstdint>
#include <array>
#include <format>
#include <unordered_map>

struct var {
    uint8_t id;
};

using var_t = var;

using reg = std::variant<uint8_t, var>;

using arg_t = std::variant<var, uint8_t>;

arg_t parse_arg(const std::string& str) {
    if (str[0] == 'v') {
        return var{static_cast<uint8_t>(std::strtol(str.c_str()+1, nullptr, 10))};
    }
    else {
        return static_cast<uint8_t>(std::stoi(str));
    }
}

void load_imm(auto& regs, uint8_t imm) {
    std::cout << "imm " << (imm&7) << std::endl;
    regs[0] = static_cast<uint8_t>(imm&7);
    if ((imm >> 3) > 0) {
        std::cout << "mov r1" << std::endl;
        regs[1] = regs[0];
        std::cout << "imm " << ((imm>>3)&7) << std::endl;
        regs[0] = static_cast<uint8_t>((imm>>3)&7);
        std::cout << "shl 3" << std::endl;
        regs[0] = static_cast<uint8_t>(std::get<uint8_t>(regs[0]) << 3);
        std::cout << "or r1" << std::endl;
        regs[1] = static_cast<uint8_t>(std::get<uint8_t>(regs[1]) | std::get<uint8_t>(regs[0]));
        if ((imm >> 6) > 0) {
            std::cout << "imm " << ((imm>>6)&7) << std::endl;
            regs[0] = static_cast<uint8_t>((imm>>6)&7);
            std::cout << "shl 6" << std::endl;
            regs[0] = static_cast<uint8_t>(std::get<uint8_t>(regs[0]) << 6);
            std::cout << "or r1" << std::endl;
            regs[1] = static_cast<uint8_t>(std::get<uint8_t>(regs[1]) | std::get<uint8_t>(regs[0]));
        }
        std::cout << "mov0 r1" << std::endl;
        regs[0] = regs[1];
    }
}

void load_arg(auto& regs, arg_t arg) {
    uint8_t imm = 0;
    if (std::holds_alternative<var>(arg)) {
        auto v = std::get<var>(arg);
        imm = v.id;
    }
    else {
        imm = std::get<uint8_t>(arg);
    }
    load_imm(regs, imm);
    if (std::holds_alternative<var>(arg)) {
        auto v = std::get<var>(arg);
        std::cout << "ld r0" << std::endl;
        regs[0] = v;
    }
}

void store_arg(auto& regs, var_t v, uint8_t r) {
    auto imm = v.id;
    load_imm(regs, imm);
    std::cout << std::format("st r{:d}", r) << std::endl;
}

void do_operation(auto& regs, std::string opcode, auto& args) {
    load_arg(regs, args[0]);
    std::cout << "mov r2" << std::endl;
    regs[2] = regs[0];
    load_arg(regs, args[1]);
    std::cout << opcode << " r2" << std::endl;
    store_arg(regs, std::get<var_t>(args[2]), 2);
    regs[2] = std::get<var_t>(args[2]);
}

std::unordered_map<std::string, std::string> branch_map{
    {"be", "bz"},
    {"bne", "bnz"},
    {"b", "b"},
    {"bg", "bgz"},
    {"bl", "blz"}
};

void branch_arg(auto& regs, std::string opcode, uint8_t r) {
    std::cout << branch_map[opcode] << std::format(" r{:d}", r) << std::endl;
}

void do_branch(auto& regs, std::string opcode, auto& args) {
    load_arg(regs, args[0]);
    std::cout << "mov r2" << std::endl;
    regs[2] = regs[0];
    load_arg(regs, args[1]);
    std::cout << "sub r2" << std::endl;
    load_arg(regs, args[2]);
    std::cout << "mov r1" << std::endl;
    std::cout << "mov0 r2" << std::endl;
    branch_arg(regs, opcode, 1);
}

int main(int argc, const char* argv[]) {
    bool enable_debug = false;
    for (int i = 1; i < argc; i++) {
        if (std::string(argv[i]) == "--debug") {
            enable_debug = true;
        }
        else if (std::string(argv[i]) == "--help") {
            std::cout << "Usage: " << argv[0] << " [options]\n"
                         "Options:\n"
                         "  --debug           Enable debug output\n"
                         "  --help            Show this help message\n";
            return 0;
        }
    }

    std::array<reg,8> regs{};
    std::array<uint8_t,256> var_to_reg{};
    while (true) {
        std::string opcode, arg0, arg1, arg2;
        std::cin >> opcode >> arg0 >> arg1 >> arg2;
        if (!std::cin.good()) {
           break;
        }
        if (enable_debug) {
            std::cerr << opcode << ',' << arg0 << arg1 << arg2 << std::endl;
        }

        std::array<arg_t,3> args{
            parse_arg(arg0),
            parse_arg(arg1),
            parse_arg(arg2)
        };
        if (branch_map.contains(opcode)) {
            do_branch(regs, opcode, args);
        }
        else {
            do_operation(regs, opcode, args);
        }
    }
    return 0;
}
