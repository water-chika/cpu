// A reference interpreter for the c16 language.
//
// This is the oracle the compiler is checked against.  It reads the same
// source and computes the same answer, but it never lowers anything: no
// registers, no spill slots, no carry flag, no labels, no instruction
// encoding.  It evaluates the grammar directly.
//
// That independence is the point.  A .expect file says "the whole stack
// agrees with the person who wrote this number", which cannot distinguish a
// correct compiler from a wrong one plus a matching mistake - and this
// session has already produced exactly that mistake once.  Two
// implementations that share no code path agree only when they are both
// right, or when they are wrong in the same way, and evaluating an
// expression tree and lowering it to a carry flag are not the sort of thing
// one is wrong about in the same way.
//
// What it does share with the compiler is the lexer, c16_lex_line, and the
// grammar it is written from.  So a lexer bug would hide from this test,
// while a bug in precedence, in the comparison lowering, in the register
// allocator's spill decisions or in the call ABI would not.  Those are where
// compilers actually go wrong.
//
// The semantics implemented here are the ones docs/c16.md documents: eight
// bit unsigned values that wrap, integer division, unsigned comparisons
// producing exactly 0 or 1, non short circuiting && and ||, and peek/poke
// against a 256 byte memory.

#ifndef C16_INTERP_HPP
#define C16_INTERP_HPP

#include "c16_kernel.hpp"

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

struct c16_interp_result {
    bool ok = false;
    std::string error;
    uint8_t out[7] = {0, 0, 0, 0, 0, 0, 0};
    uint32_t out_mask = 0;
    uint64_t steps = 0;
    std::vector<uint8_t> data;
};

class c16_interpreter {
public:
    c16_interpreter(const std::vector<char>& source, const std::vector<uint8_t>& data_init,
                    uint64_t max_steps)
        : source_(source), max_steps_(max_steps) {
        data_.assign(256, 0);
        for (size_t i = 0; i < data_init.size() && i < 256; i++) {
            data_[i] = data_init[i];
        }
    }

    c16_interp_result run() {
        c16_interp_result result;
        if (!lex() || !collect()) {
            result.error = error_;
            return result;
        }
        auto main_it = functions_.find("main");
        if (main_it == functions_.end()) {
            result.error = "no main()";
            return result;
        }
        for (const global& g : globals_) {
            variables_[g.name] = g.init;
        }
        std::vector<uint8_t> none;
        uint8_t ignored = 0;
        if (!call(main_it->second, none, ignored)) {
            result.error = error_;
            return result;
        }
        result.ok = true;
        result.out_mask = out_mask_;
        for (int i = 0; i < 7; i++) {
            result.out[i] = out_[i];
        }
        result.steps = steps_;
        result.data = data_;
        return result;
    }

private:
    struct func {
        std::vector<std::string_view> params;
        uint32_t body_begin = 0;   // index of the '{'
        uint32_t body_end = 0;     // index just past the matching '}'
    };
    struct global {
        std::string name;
        uint8_t init;
    };
    // Control flow is reported by a signal rather than by exceptions, so the
    // interpreter has no hidden cost and is easy to reason about.
    enum class flow { normal, brk, cont, ret };

    // ------------------------------------------------------------- front

    bool lex() {
        size_t begin = 0;
        uint32_t line_no = 1;
        while (begin <= source_.size()) {
            size_t end = begin;
            while (end < source_.size() && source_[end] != '\n') {
                end++;
            }
            asm_span span{};
        span.off = static_cast<uint32_t>(begin);
        span.len = static_cast<uint32_t>(end - begin);
            uint32_t count = c16_lex_line(source_.data(), span, line_no, nullptr);
            size_t at = tokens_.size();
            tokens_.resize(at + count);
            c16_lex_line(source_.data(), span, line_no, tokens_.data() + at);
            if (end >= source_.size()) {
                break;
            }
            begin = end + 1;
            line_no++;
        }
        c16_token end{};
        end.kind = C16_TOK_END;
        end.line = line_no;
        tokens_.push_back(end);
        return true;
    }

    uint16_t kind(size_t i) const {
        return i < tokens_.size() ? tokens_[i].kind : static_cast<uint16_t>(C16_TOK_END);
    }
    std::string_view text(size_t i) const {
        const c16_token& t = tokens_[i];
        return std::string_view(source_.data() + t.off, t.len);
    }

    // Walk the top level once, recording where each function's body is and
    // what the globals start at.
    bool collect() {
        size_t i = 0;
        while (kind(i) != C16_TOK_END) {
            if (kind(i) != C16_TOK_INT || kind(i + 1) != C16_TOK_IDENT) {
                error_ = "expected a declaration at the top level";
                return false;
            }
            std::string_view name = text(i + 1);
            if (kind(i + 2) != C16_TOK_LPAREN) {
                uint8_t init = 0;
                size_t j = i + 2;
                if (kind(j) == C16_TOK_ASSIGN) {
                    j++;
                    int32_t sign = 1;
                    if (kind(j) == C16_TOK_MINUS) {
                        sign = -1;
                        j++;
                    }
                    if (kind(j) != C16_TOK_NUMBER) {
                        error_ = "a global's initialiser has to be an integer literal";
                        return false;
                    }
                    init = static_cast<uint8_t>(sign * tokens_[j].value);
                    j++;
                }
                if (kind(j) != C16_TOK_SEMI) {
                    error_ = "expected ';' after a global";
                    return false;
                }
                globals_.push_back({std::string(name), init});
                i = j + 1;
                continue;
            }
            func f;
            size_t j = i + 3;
            while (kind(j) == C16_TOK_INT && kind(j + 1) == C16_TOK_IDENT) {
                f.params.push_back(text(j + 1));
                j += 2;
                if (kind(j) == C16_TOK_COMMA) {
                    j++;
                }
            }
            if (kind(j) != C16_TOK_RPAREN || kind(j + 1) != C16_TOK_LBRACE) {
                error_ = "expected ') {' after the parameters of '" + std::string(name) + "'";
                return false;
            }
            f.body_begin = static_cast<uint32_t>(j + 1);
            size_t depth = 0;
            size_t k = f.body_begin;
            for (; kind(k) != C16_TOK_END; k++) {
                if (kind(k) == C16_TOK_LBRACE) {
                    depth++;
                }
                else if (kind(k) == C16_TOK_RBRACE) {
                    depth--;
                    if (depth == 0) {
                        break;
                    }
                }
            }
            if (kind(k) != C16_TOK_RBRACE) {
                error_ = "'" + std::string(name) + "' is missing a closing '}'";
                return false;
            }
            f.body_end = static_cast<uint32_t>(k + 1);
            functions_[std::string(name)] = f;
            i = f.body_end;
        }
        return true;
    }

    // ------------------------------------------------------- environment

    // A scope is a list of names; leaving one forgets them again.  Globals
    // live at the bottom and are never forgotten.
    struct scope_mark {
        size_t names;
    };

    bool lookup(std::string_view name, uint8_t** slot) {
        auto it = variables_.find(std::string(name));
        if (it == variables_.end()) {
            return false;
        }
        *slot = &it->second;
        return true;
    }

    // --------------------------------------------------------- execution

    bool call(const func& f, const std::vector<uint8_t>& args, uint8_t& out) {
        if (depth_ > 64) {
            error_ = "the interpreter's call depth ran away";
            return false;
        }
        // Parameters and locals shadow anything outside; saving and
        // restoring the whole map is slow but obviously correct, and the
        // programs here are tiny.
        std::unordered_map<std::string, uint8_t> saved = variables_;
        size_t decl_mark = declared_.size();
        for (size_t i = 0; i < f.params.size() && i < args.size(); i++) {
            variables_[std::string(f.params[i])] = args[i];
            declared_.push_back(std::string(f.params[i]));
        }
        depth_++;
        size_t pos = f.body_begin;
        uint8_t value = 0;
        flow how = flow::normal;
        bool ok = block(pos, value, how);
        depth_--;
        // Globals are shared, so whatever the call did to them survives.
        // Nothing else does: arguments are passed by value and the language
        // has no pointers, so the callee cannot reach a caller's variable.
        // Copying back every name the callee happened to touch would be
        // wrong, because a local or a parameter in the callee may share a
        // name with a live variable in the caller and would silently
        // overwrite it.
        for (const global& g : globals_) {
            bool shadowed = false;
            for (size_t i = decl_mark; i < declared_.size(); i++) {
                if (declared_[i] == g.name) {
                    shadowed = true;   // the callee declared its own g
                    break;
                }
            }
            if (shadowed) {
                continue;
            }
            auto it = variables_.find(g.name);
            if (it != variables_.end()) {
                saved[g.name] = it->second;
            }
        }
        declared_.resize(decl_mark);
        variables_ = std::move(saved);
        out = how == flow::ret ? value : 0;
        return ok;
    }

    bool step() {
        if (++steps_ > max_steps_) {
            error_ = "the program did not finish within " + std::to_string(max_steps_) +
                     " steps";
            return false;
        }
        return true;
    }

    // pos is at '{' on entry and just past the matching '}' on return.
    bool block(size_t& pos, uint8_t& value, flow& how) {
        pos++;   // '{'
        while (kind(pos) != C16_TOK_RBRACE) {
            if (kind(pos) == C16_TOK_END) {
                error_ = "missing '}'";
                return false;
            }
            if (!statement(pos, value, how)) {
                return false;
            }
            if (how != flow::normal) {
                // Skip the rest of the block without running it.
                size_t depth = 1;
                while (depth > 0 && kind(pos) != C16_TOK_END) {
                    if (kind(pos) == C16_TOK_LBRACE) {
                        depth++;
                    }
                    else if (kind(pos) == C16_TOK_RBRACE) {
                        depth--;
                        if (depth == 0) {
                            break;
                        }
                    }
                    pos++;
                }
                break;
            }
        }
        pos++;   // '}'
        return true;
    }

    void skip_block(size_t& pos) {
        size_t depth = 0;
        do {
            if (kind(pos) == C16_TOK_LBRACE) {
                depth++;
            }
            else if (kind(pos) == C16_TOK_RBRACE) {
                depth--;
            }
            pos++;
        } while (depth > 0 && kind(pos) != C16_TOK_END);
    }

    bool statement(size_t& pos, uint8_t& value, flow& how) {
        if (!step()) {
            return false;
        }
        switch (kind(pos)) {
        case C16_TOK_SEMI:
            pos++;
            return true;
        case C16_TOK_LBRACE:
            return block(pos, value, how);
        case C16_TOK_INT: {
            pos++;
            if (kind(pos) != C16_TOK_IDENT) {
                error_ = "expected a name after 'int'";
                return false;
            }
            std::string name(text(pos));
            pos++;
            uint8_t v = 0;
            if (kind(pos) == C16_TOK_ASSIGN) {
                pos++;
                if (!expression(pos, v)) {
                    return false;
                }
            }
            variables_[name] = v;
            declared_.push_back(name);
            pos++;   // ';'
            return true;
        }
        case C16_TOK_IF: {
            pos += 2;   // "if" "("
            uint8_t cond = 0;
            if (!expression(pos, cond)) {
                return false;
            }
            pos++;   // ')'
            if (cond != 0) {
                if (!block(pos, value, how)) {
                    return false;
                }
                if (kind(pos) == C16_TOK_ELSE) {
                    pos++;
                    skip_block(pos);
                }
            }
            else {
                skip_block(pos);
                if (kind(pos) == C16_TOK_ELSE) {
                    pos++;
                    if (!block(pos, value, how)) {
                        return false;
                    }
                }
            }
            return true;
        }
        case C16_TOK_WHILE: {
            size_t head = pos;
            for (;;) {
                pos = head + 2;   // "while" "("
                uint8_t cond = 0;
                if (!expression(pos, cond)) {
                    return false;
                }
                pos++;   // ')'
                if (cond == 0) {
                    skip_block(pos);
                    return true;
                }
                flow inner = flow::normal;
                if (!block(pos, value, inner)) {
                    return false;
                }
                if (inner == flow::brk) {
                    return true;
                }
                if (inner == flow::ret) {
                    how = flow::ret;
                    return true;
                }
                if (!step()) {
                    return false;
                }
            }
        }
        case C16_TOK_BREAK:
            pos += 2;
            how = flow::brk;
            return true;
        case C16_TOK_CONTINUE:
            pos += 2;
            how = flow::cont;
            return true;
        case C16_TOK_RETURN: {
            pos++;
            uint8_t v = 0;
            if (kind(pos) != C16_TOK_SEMI) {
                if (!expression(pos, v)) {
                    return false;
                }
            }
            pos++;   // ';'
            value = v;
            how = flow::ret;
            return true;
        }
        default:
            break;
        }
        // Assignment, or a bare expression such as a call.
        if (kind(pos) == C16_TOK_IDENT && kind(pos + 1) == C16_TOK_ASSIGN) {
            std::string name(text(pos));
            pos += 2;
            uint8_t v = 0;
            if (!expression(pos, v)) {
                return false;
            }
            uint8_t* slot = nullptr;
            if (!lookup(name, &slot)) {
                error_ = "unknown variable '" + name + "'";
                return false;
            }
            *slot = v;
            pos++;   // ';'
            return true;
        }
        uint8_t discard = 0;
        if (!expression(pos, discard)) {
            return false;
        }
        pos++;   // ';'
        return true;
    }

    // ------------------------------------------------------- expressions

    // The same precedence ladder docs/c16.md documents, lowest first.
    bool expression(size_t& pos, uint8_t& v) { return oror(pos, v); }

    bool oror(size_t& pos, uint8_t& v) {
        if (!andand(pos, v)) {
            return false;
        }
        while (kind(pos) == C16_TOK_OROR) {
            pos++;
            uint8_t b = 0;
            if (!andand(pos, b)) {
                return false;
            }
            // Deliberately not short circuiting, exactly like the compiler:
            // both sides run, then both are normalised to 0 or 1.
            v = static_cast<uint8_t>((v != 0) | (b != 0));
        }
        return true;
    }
    bool andand(size_t& pos, uint8_t& v) {
        if (!bitor_(pos, v)) {
            return false;
        }
        while (kind(pos) == C16_TOK_ANDAND) {
            pos++;
            uint8_t b = 0;
            if (!bitor_(pos, b)) {
                return false;
            }
            v = static_cast<uint8_t>((v != 0) & (b != 0));
        }
        return true;
    }
    bool bitor_(size_t& pos, uint8_t& v) {
        if (!bitxor_(pos, v)) {
            return false;
        }
        while (kind(pos) == C16_TOK_PIPE) {
            pos++;
            uint8_t b = 0;
            if (!bitxor_(pos, b)) {
                return false;
            }
            v = static_cast<uint8_t>(v | b);
        }
        return true;
    }
    bool bitxor_(size_t& pos, uint8_t& v) {
        if (!bitand_(pos, v)) {
            return false;
        }
        while (kind(pos) == C16_TOK_CARET) {
            pos++;
            uint8_t b = 0;
            if (!bitand_(pos, b)) {
                return false;
            }
            v = static_cast<uint8_t>(v ^ b);
        }
        return true;
    }
    bool bitand_(size_t& pos, uint8_t& v) {
        if (!equality(pos, v)) {
            return false;
        }
        while (kind(pos) == C16_TOK_AMP) {
            pos++;
            uint8_t b = 0;
            if (!equality(pos, b)) {
                return false;
            }
            v = static_cast<uint8_t>(v & b);
        }
        return true;
    }
    bool equality(size_t& pos, uint8_t& v) {
        if (!relational(pos, v)) {
            return false;
        }
        for (;;) {
            uint16_t k = kind(pos);
            if (k != C16_TOK_EQ && k != C16_TOK_NE) {
                return true;
            }
            pos++;
            uint8_t b = 0;
            if (!relational(pos, b)) {
                return false;
            }
            v = static_cast<uint8_t>(k == C16_TOK_EQ ? (v == b) : (v != b));
        }
    }
    bool relational(size_t& pos, uint8_t& v) {
        if (!shift(pos, v)) {
            return false;
        }
        for (;;) {
            uint16_t k = kind(pos);
            if (k != C16_TOK_LT && k != C16_TOK_GT && k != C16_TOK_LE && k != C16_TOK_GE) {
                return true;
            }
            pos++;
            uint8_t b = 0;
            if (!shift(pos, b)) {
                return false;
            }
            // Unsigned, because the carry flag these are built on is an
            // unsigned borrow.
            switch (k) {
            case C16_TOK_LT: v = static_cast<uint8_t>(v < b); break;
            case C16_TOK_GT: v = static_cast<uint8_t>(v > b); break;
            case C16_TOK_LE: v = static_cast<uint8_t>(v <= b); break;
            default:         v = static_cast<uint8_t>(v >= b); break;
            }
        }
    }
    bool shift(size_t& pos, uint8_t& v) {
        if (!additive(pos, v)) {
            return false;
        }
        for (;;) {
            uint16_t k = kind(pos);
            if (k != C16_TOK_SHL && k != C16_TOK_SHR) {
                return true;
            }
            pos++;
            uint8_t b = 0;
            if (!additive(pos, b)) {
                return false;
            }
            unsigned s = b & 7;
            v = static_cast<uint8_t>(k == C16_TOK_SHL ? (v << s) : (v >> s));
        }
    }
    bool additive(size_t& pos, uint8_t& v) {
        if (!multiplicative(pos, v)) {
            return false;
        }
        for (;;) {
            uint16_t k = kind(pos);
            if (k != C16_TOK_PLUS && k != C16_TOK_MINUS) {
                return true;
            }
            pos++;
            uint8_t b = 0;
            if (!multiplicative(pos, b)) {
                return false;
            }
            v = static_cast<uint8_t>(k == C16_TOK_PLUS ? (v + b) : (v - b));
        }
    }
    bool multiplicative(size_t& pos, uint8_t& v) {
        if (!unary(pos, v)) {
            return false;
        }
        for (;;) {
            uint16_t k = kind(pos);
            if (k != C16_TOK_STAR && k != C16_TOK_SLASH) {
                return true;
            }
            pos++;
            uint8_t b = 0;
            if (!unary(pos, b)) {
                return false;
            }
            if (k == C16_TOK_SLASH) {
                if (b == 0) {
                    error_ = "divide by zero, which the hardware leaves undefined";
                    return false;
                }
                v = static_cast<uint8_t>(v / b);
            }
            else {
                v = static_cast<uint8_t>(v * b);
            }
        }
    }
    bool unary(size_t& pos, uint8_t& v) {
        uint16_t k = kind(pos);
        if (k == C16_TOK_MINUS || k == C16_TOK_BANG || k == C16_TOK_TILDE) {
            pos++;
            if (!unary(pos, v)) {
                return false;
            }
            switch (k) {
            case C16_TOK_MINUS: v = static_cast<uint8_t>(-static_cast<int>(v)); break;
            case C16_TOK_BANG:   v = static_cast<uint8_t>(v == 0); break;
            default:            v = static_cast<uint8_t>(~v); break;
            }
            return true;
        }
        return primary(pos, v);
    }

    bool primary(size_t& pos, uint8_t& v) {
        if (!step()) {
            return false;
        }
        if (kind(pos) == C16_TOK_NUMBER) {
            v = static_cast<uint8_t>(tokens_[pos].value);
            pos++;
            return true;
        }
        if (kind(pos) == C16_TOK_LPAREN) {
            pos++;
            if (!expression(pos, v)) {
                return false;
            }
            pos++;   // ')'
            return true;
        }
        if (kind(pos) != C16_TOK_IDENT) {
            error_ = "expected an expression";
            return false;
        }
        std::string name(text(pos));
        if (kind(pos + 1) != C16_TOK_LPAREN) {
            uint8_t* slot = nullptr;
            if (!lookup(name, &slot)) {
                error_ = "unknown variable '" + name + "'";
                return false;
            }
            v = *slot;
            pos++;
            return true;
        }
        pos += 2;   // name '('
        std::vector<uint8_t> args;
        while (kind(pos) != C16_TOK_RPAREN) {
            uint8_t a = 0;
            if (!expression(pos, a)) {
                return false;
            }
            args.push_back(a);
            if (kind(pos) == C16_TOK_COMMA) {
                pos++;
            }
        }
        pos++;   // ')'

        if (name == "peek") {
            v = data_[args.empty() ? 0 : args[0]];
            return true;
        }
        if (name == "poke") {
            if (args.size() >= 2) {
                data_[args[0]] = args[1];
            }
            v = 0;
            return true;
        }
        if (name == "out") {
            if (args.size() >= 2 && args[0] < 7) {
                out_[args[0]] = args[1];
                out_mask_ |= 1u << args[0];
            }
            v = 0;
            return true;
        }
        auto it = functions_.find(name);
        if (it == functions_.end()) {
            error_ = "unknown function '" + name + "'";
            return false;
        }
        return call(it->second, args, v);
    }

    const std::vector<char>& source_;
    uint64_t max_steps_;
    uint64_t steps_ = 0;
    unsigned depth_ = 0;
    std::string error_;
    std::vector<c16_token> tokens_;
    std::unordered_map<std::string, func> functions_;
    std::vector<global> globals_;
    std::unordered_map<std::string, uint8_t> variables_;
    std::vector<std::string> declared_;   // names a call brought into scope
    std::vector<uint8_t> data_;
    uint8_t out_[7] = {0, 0, 0, 0, 0, 0, 0};
    uint32_t out_mask_ = 0;
};

inline c16_interp_result c16_interpret(const std::vector<char>& source,
                                       const std::vector<uint8_t>& data_init,
                                       uint64_t max_steps = 10000000) {
    c16_interpreter interp(source, data_init, max_steps);
    return interp.run();
}

#endif  // C16_INTERP_HPP
