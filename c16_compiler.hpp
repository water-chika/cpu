#ifndef C16_COMPILER_HPP
#define C16_COMPILER_HPP

// The host half of the c16 compiler: a small C like language lowered to
// cpu16.
//
// The shape of it deliberately mirrors the assembler next door.  A serial
// spine that has to see the program in order, with the bulk of the work
// hanging off it in passes that are independent per item:
//
//   lex      per source line, parallel          (c16_lex_line)
//   split    one ordered scan for brace depth, which is what finds the
//            function boundaries.  Serial, and honest about it.
//   size     per function, parallel: how many bytes of frame it needs
//   lower    per function, parallel: recursive descent straight to cpu16
//            items.  This is the real work and the real parallel axis.
//   layout   a prefix sum over functions (serial, one entry per function)
//            followed by a parallel fill that gives every item its address
//            and every label its value
//   resolve  per item, parallel: look a label reference up
//   emit     per item, parallel, on one of two paths:
//              text   - format cpu16 assembly the existing asm16 assembles
//              binary - hand the item to the assembler's own encoder and
//                       get machine words, with no text in between
//
// Backends are chosen with the environment, the way the assembler's are:
//
//   C16_BACKEND=serial|threads|hip|auto   (default auto)
//   C16_THREADS=<n>                       (default hardware_concurrency)

#include "asm_pipeline.hpp"
#include "c16_kernel.hpp"

#include <algorithm>
#include <cstdint>
#include <format>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

// ------------------------------------------------------------- the target

// cpu16 has 256 bytes of data memory and 256 instruction words, and neither
// number is negotiable, so the whole language is built around this map.
constexpr uint32_t C16_USER_BASE     = 0;    // 0..63    free for the program: peek/poke, +data files
constexpr uint32_t C16_USER_SIZE     = 64;
constexpr uint32_t C16_VAR_BASE      = 64;   // 64..159  globals, then one fixed frame per function
constexpr uint32_t C16_VAR_SIZE      = 96;
constexpr uint32_t C16_SPILL_BASE    = 160;  // 160..191 the expression stack, once it leaves registers
constexpr uint32_t C16_SPILL_SIZE    = 32;
constexpr uint32_t C16_OUT_BASE      = 192;  // 192..198 out(0)..out(6), loaded into r0..r6 at the end
constexpr uint32_t C16_OUT_SLOTS     = 7;
constexpr uint32_t C16_PROGRAM_WORDS = 256;

// Registers.  Expression stack slots 0..4 live in r0..r4; deeper slots live
// in the spill area and are brought into r5 and r6 one operation at a time.
// r7 is never a value: it carries addresses and branch targets.
constexpr int8_t C16_REG_SLOTS     = 5;
constexpr int8_t C16_REG_SCRATCH_A = 5;
constexpr int8_t C16_REG_SCRATCH_B = 6;
constexpr int8_t C16_REG_ADDR      = 7;

constexpr uint32_t C16_MAX_SLOTS    = C16_SPILL_SIZE;   // deepest expression the stack can hold
constexpr uint32_t C16_MAX_PARAMS   = 8;
constexpr uint32_t C16_ENTRY_LABEL  = 0;                // local label 0 of every function
constexpr uint32_t C16_EXIT_LABEL   = 1;                // local label 1 of main
constexpr uint32_t C16_FUNCTION_TAG = 0x80000000u;      // "this label id names a function entry"

// cpu16 opcodes the compiler emits.
constexpr uint8_t C16_OP_AND = 0,  C16_OP_OR = 1,     C16_OP_NOT = 2,  C16_OP_XOR = 3;
constexpr uint8_t C16_OP_ADD = 4,  C16_OP_ADC = 5,    C16_OP_SUB = 6,  C16_OP_NEG = 8;
constexpr uint8_t C16_OP_MUL = 9,  C16_OP_DIV = 10,   C16_OP_MOV = 11, C16_OP_IMM = 12;
constexpr uint8_t C16_OP_IMM_S = 13, C16_OP_SHL = 14, C16_OP_SHR = 15;
constexpr uint8_t C16_OP_BNZ = 32, C16_OP_BZ = 33,    C16_OP_B = 34;
constexpr uint8_t C16_OP_LD = 64,  C16_OP_ST = 65,    C16_OP_CL = 66;

// ------------------------------------------------------------- diagnostics

struct c16_error {
    bool failed = false;
    uint32_t line = 0;
    uint32_t token = 0;    // position in the flat token array, to order errors
    std::string message;
};

enum class c16_backend { serial, threads, hip };

struct c16_options {
    c16_backend backend = c16_backend::serial;
    unsigned threads = 1;
    bool text = true;             // text path, rather than the binary path
    bool hex = true;              // binary path: hex digits rather than raw words
    bool sep_with_line = true;    // hex only: newline rather than comma
    // The benchmark compiles programs far larger than the CPU could ever
    // run, purely to have something worth timing.  It is the only caller
    // that sets this, and it lifts exactly two limits: the 256 instruction
    // words and the 96 bytes of frame space.  Every other byte of the work
    // is what the real compiler does.
    bool relaxed_limits = false;
    // The variables-in-registers stage (docs/c16.md, "Variables in
    // registers").  Off is the older behaviour - every named variable lives in
    // its frame byte - and it stays reachable so that a test can compile a
    // program both ways and compare what the two programs compute.
    bool registers_for_variables = true;
};

struct c16_stats {
    double lex = 0;
    double split = 0;
    double size = 0;
    double lower = 0;
    double layout = 0;
    double resolve = 0;
    double emit = 0;
    size_t lines = 0;
    size_t tokens = 0;
    size_t functions = 0;
    size_t items = 0;
    size_t words = 0;
    size_t input_bytes = 0;
    unsigned threads = 1;
};

struct c16_result {
    bool ok = false;
    c16_error error;
    asm_array<uint8_t> output;
    c16_stats stats;
};

// ------------------------------------------------------------- symbols

struct c16_function {
    std::string_view name;
    uint32_t name_token = 0;
    uint32_t nparams = 0;
    uint32_t param_token[C16_MAX_PARAMS] = {};
    uint32_t body_begin = 0;      // index of the '{'
    uint32_t body_end = 0;        // index of the matching '}'
    uint32_t nlocals = 0;         // "int" declarations inside the body
    uint32_t frame = 0;           // frame base address in data memory
    uint32_t frame_size = 0;      // 1 return address + params + locals
};

struct c16_global {
    std::string_view name;
    uint32_t address = 0;
    int32_t init = 0;
};

// What one function's lowering produced.  Labels and function entry
// references are still local here; the layout pass renumbers them.
struct c16_lowered {
    std::vector<c16_item> items;
    std::vector<uint32_t> calls;
    uint32_t nlabels = 0;
    uint32_t words = 0;
    uint32_t out_mask = 0;
    c16_error error;
};

// ------------------------------------------------------------- lowering

// One variable's claim on a register.  The interval is in token positions,
// which is a conservative superset of a real live range: it covers positions
// between two uses whether or not the variable is live there, and that is the
// direction in which it is safe to be wrong.  See docs/c16.md, "Variables in
// registers".
struct c16_var_use {
    uint32_t address = 0;
    uint32_t first = 0;
    uint32_t last = 0;
    uint64_t weight = 0;
};

// A recursive descent parser that emits cpu16 as it goes.  There is no AST:
// the language has no construct that needs one, and a single pass keeps the
// per function work a tight loop over its own token range, which is what
// makes lowering the whole program parallel across functions.
class c16_lowerer {
public:
    c16_lowerer(const std::vector<char>& source,
                const std::vector<c16_token>& tokens,
                const std::vector<c16_function>& functions,
                const std::unordered_map<std::string_view, uint32_t>& function_index,
                const std::vector<c16_global>& globals,
                const std::unordered_map<std::string_view, uint32_t>& global_index,
                uint32_t self,
                bool allocate = true)
        : source_(source), tokens_(tokens), functions_(functions),
          function_index_(function_index), globals_(globals),
          global_index_(global_index), self_(self), allocate_(allocate) {}

    // forced_out_mask lets the driver re-run main once the union of every
    // function's out() slots is known: only main's epilogue depends on it.
    //
    // Lowering a function happens twice when the variables-in-registers stage
    // is on: once with emission switched off, to find out which variables are
    // worth a register and which registers the expression stack leaves free,
    // and once for real with that map in hand.  Parsing twice rather than
    // scanning once is what keeps the frame addresses and the scoping
    // identical between the two - the same code hands them out.  A failure in
    // the analysis pass is not reported from there: the real pass hits it
    // again and reports it, with the allocation empty.
    c16_lowered run(uint32_t forced_out_mask = 0) {
        if (allocate_) {
            analysing_ = true;
            lower_function(forced_out_mask);
            analysing_ = false;
            if (!out_.error.failed) {
                allocate_registers();
            }
            out_ = c16_lowered{};
        }
        lower_function(forced_out_mask);
        return std::move(out_);
    }

private:
    void lower_function(uint32_t forced_out_mask) {
        const c16_function& f = functions_[self_];
        out_.out_mask = forced_out_mask;
        pos_ = f.body_begin + 1;
        end_ = f.body_end;
        next_local_ = f.frame + 1 + f.nparams;
        bindings_.clear();
        scope_mark_.clear();
        loops_.clear();
        loop_depth_ = 0;
        addr_cache_ = -1;
        if (analysing_) {
            uses_.clear();
            loop_spans_.clear();
            max_slot_ = 0;
            saw_call_ = false;
            saw_raw_memory_ = false;
        }

        label(C16_ENTRY_LABEL);     // every function's entry is its label 0
        out_.nlabels = self_ == 0 ? 2 : 1;   // main also reserves its exit label

        push_scope();
        for (uint32_t i = 0; i < f.nparams; i++) {
            declare(text(tokens_[f.param_token[i]]), f.frame + 1 + i);
        }
        // A parameter is defined at entry, not where it is first read, so its
        // interval has to start here.  Without this, "return a + b" gives both
        // of them a one token interval, they look disjoint, and they are
        // handed the same register.  Weight 0: only real references earn one.
        if (analysing_) {
            for (uint32_t i = 0; i < f.nparams; i++) {
                uses_.push_back(c16_var_use{f.frame + 1 + i, pos_, pos_, 0});
            }
        }
        // A promoted parameter is read out of its frame byte once, here: the
        // caller had nowhere else to put it.
        for (uint32_t i = 0; i < f.nparams; i++) {
            int8_t home = var_register(f.frame + 1 + i);
            if (home >= 0) {
                constant(C16_REG_ADDR, static_cast<uint8_t>(f.frame + 1 + i));
                insn(C16_OP_LD, 0, C16_REG_ADDR, home);
            }
        }
        if (self_ == 0) {
            // Globals are initialised by main, before anything else runs.
            for (const c16_global& g : globals_) {
                constant(0, static_cast<uint8_t>(g.init));
                constant(C16_REG_ADDR, static_cast<uint8_t>(g.address));
                insn(C16_OP_ST, 0, C16_REG_ADDR, 0);
            }
        }
        statements();
        pop_scope();

        // Falling off the end of a function is "return 0".
        if (!out_.error.failed) {
            constant(0, 0);
            emit_return();
        }
        if (self_ == 0 && !out_.error.failed) {
            epilogue();
        }
    }
    // ---------------------------------------------------------- emitting

    void insn(uint8_t opcode, int8_t a0, int8_t a1, int8_t a2) {
        if (analysing_) {
            return;
        }
        c16_item it{};
        it.kind = C16_ITEM_INSN;
        it.opcode = opcode;
        it.arg[0] = a0;
        it.arg[1] = a1;
        it.arg[2] = a2;
        if (a2 == C16_REG_ADDR) {
            addr_cache_ = -1;   // whatever r7 held, this instruction just overwrote it
        }
        out_.items.push_back(it);
        out_.words += 1;
    }

    void la(int8_t dst, uint32_t label_id) {
        if (analysing_) {
            return;
        }
        c16_item it{};
        it.kind = C16_ITEM_LA;
        it.arg[0] = dst;
        it.label = label_id;
        if (dst == C16_REG_ADDR) {
            addr_cache_ = -1;
        }
        out_.items.push_back(it);
        out_.words += asm_cpu16::la_words;
    }

    void label(uint32_t id) {
        if (analysing_) {
            return;
        }
        c16_item it{};
        it.kind = C16_ITEM_LABEL;
        it.label = id;
        addr_cache_ = -1;   // control flow joins here, so nothing is known any more
        out_.items.push_back(it);
    }

    uint32_t new_label() { return out_.nlabels++; }

    // ------------------------------------ variables in registers: analysis

    // The deepest expression stack slot this function reaches.  Registers
    // above it are provably free, which is the whole budget this stage has.
    void note_slot(uint32_t slot) {
        if (analysing_ && slot < static_cast<uint32_t>(C16_REG_SLOTS) && slot > max_slot_) {
            max_slot_ = slot;
        }
    }

    // A reference to a variable, at the position the parser has reached.
    // Only this function's own frame counts: globals are shared with every
    // other function and byte 0 of the frame is the return address.
    void note_use(uint32_t address) {
        if (!analysing_) {
            return;
        }
        const c16_function& f = functions_[self_];
        if (address <= f.frame || address >= f.frame + f.frame_size) {
            return;
        }
        uint32_t d = loop_depth_ > 3 ? 3 : loop_depth_;
        uint64_t weight = 1ull << (3 * d);
        for (c16_var_use& u : uses_) {
            if (u.address == address) {
                u.first = std::min(u.first, pos_);
                u.last = std::max(u.last, pos_);
                u.weight += weight;
                return;
            }
        }
        uses_.push_back(c16_var_use{address, pos_, pos_, weight});
    }

    // Which register holds this variable, or -1 for "its frame byte does".
    int8_t var_register(uint32_t address) const {
        return allocated_.empty() ? -1 : allocated_[address];
    }

    // The allocation itself: linear scan over the intervals, into the
    // registers the expression stack does not need.  docs/c16.md, "Variables
    // in registers", is the argument for every line of this.
    void allocate_registers() {
        allocated_.clear();
        if (saw_call_ || saw_raw_memory_ || uses_.empty()) {
            return;
        }
        int8_t first_free = static_cast<int8_t>(max_slot_ + 1);
        if (first_free < 1) {
            first_free = 1;     // r0 is where a return value has to land
        }
        if (first_free >= C16_REG_SLOTS) {
            return;
        }

        // Widen every interval over any loop it touches, to a fixed point.  A
        // loop's back edge puts a later write ahead of an earlier read, so two
        // intervals that merely look disjoint inside a loop are not.
        bool changed = true;
        while (changed) {
            changed = false;
            for (c16_var_use& u : uses_) {
                for (const std::pair<uint32_t, uint32_t>& l : loop_spans_) {
                    if (u.first <= l.second && l.first <= u.last &&
                        (l.first < u.first || l.second > u.last)) {
                        u.first = std::min(u.first, l.first);
                        u.last = std::max(u.last, l.second);
                        changed = true;
                    }
                }
            }
        }

        std::vector<uint32_t> order(uses_.size());
        for (uint32_t i = 0; i < order.size(); i++) {
            order[i] = i;
        }
        // Hottest first, and by address when two are equally hot, so that the
        // result does not depend on declaration order alone or on anything a
        // thread did.
        std::sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) {
            if (uses_[a].weight != uses_[b].weight) {
                return uses_[a].weight > uses_[b].weight;
            }
            return uses_[a].address < uses_[b].address;
        });

        std::vector<std::vector<uint32_t>> held(C16_REG_SLOTS);
        std::vector<int8_t> map(256, -1);
        bool any = false;
        for (uint32_t i : order) {
            // A parameter arrives in its frame byte, so promoting it costs a
            // load in the prologue.  One reference does not pay for that.
            const c16_function& f = functions_[self_];
            bool is_param = uses_[i].address <= f.frame + f.nparams;
            if (is_param && uses_[i].weight < 2) {
                continue;
            }
            for (int8_t r = first_free; r < C16_REG_SLOTS; r++) {
                bool clash = false;
                for (uint32_t j : held[r]) {
                    if (uses_[i].first <= uses_[j].last && uses_[j].first <= uses_[i].last) {
                        clash = true;
                        break;
                    }
                }
                if (clash) {
                    continue;
                }
                held[r].push_back(i);
                map[uses_[i].address] = r;
                any = true;
                break;
            }
            // No register fits: the variable keeps its frame byte.  That is
            // the old behaviour, and it is always correct, which is why this
            // stage has no spilling of its own.
        }
        if (any) {
            allocated_ = std::move(map);
        }
    }

    // Build an 8 bit constant in a register.  cpu16's "imm" writes
    // (value << shift) and "imm_s" ors it in, with three bits of each, so any
    // byte is three groups at shifts 6, 3 and 0.  Groups that are zero are
    // skipped, except that the first group emitted has to be the assigning
    // "imm" rather than the or-ing "imm_s".  One to three words.
    // Addresses are constants, and the same address gets rebuilt again and
    // again - "load x, operate, store x" alone materialises it twice - so r7
    // carries a one entry cache of the constant it already holds.  Anything
    // that writes r7, and any label, drops it.  This is the only peephole in
    // the compiler, and it is worth about a third of the program size.
    void constant(int8_t reg, uint8_t value) {
        if (reg == C16_REG_ADDR && addr_cache_ == static_cast<int>(value)) {
            return;
        }
        int8_t group[3] = {static_cast<int8_t>((value >> 6) & 3),
                           static_cast<int8_t>((value >> 3) & 7),
                           static_cast<int8_t>(value & 7)};
        const int8_t shift[3] = {6, 3, 0};
        bool first = true;
        for (int i = 0; i < 3; i++) {
            if (group[i] == 0) {
                continue;
            }
            insn(first ? C16_OP_IMM : C16_OP_IMM_S, group[i], shift[i], reg);
            first = false;
        }
        if (first) {
            insn(C16_OP_IMM, 0, 0, reg);
        }
        if (reg == C16_REG_ADDR) {
            addr_cache_ = static_cast<int>(value);
        }
    }

    void jump(uint32_t label_id) {
        la(C16_REG_ADDR, label_id);
        insn(C16_OP_B, 0, C16_REG_ADDR, 0);
    }

    void branch_if_zero(int8_t reg, uint32_t label_id) {
        la(C16_REG_ADDR, label_id);
        insn(C16_OP_BZ, reg, C16_REG_ADDR, 0);
    }

    // ---------------------------------------------------- the value stack

    // The expression stack.  Slot k is register k while k is small enough,
    // and a byte of the spill area otherwise.  Which it is never depends on
    // anything but k, so no allocation state has to be threaded through the
    // recursion.
    static bool in_register(uint32_t slot) { return slot < static_cast<uint32_t>(C16_REG_SLOTS); }
    static uint8_t spill_address(uint32_t slot) {
        return static_cast<uint8_t>(C16_SPILL_BASE + slot);
    }

    // Get slot's value into a register, using the given scratch if it is
    // spilled.  Costs nothing at all for the common shallow case.
    int8_t materialise(uint32_t slot, int8_t scratch) {
        note_slot(slot);
        if (in_register(slot)) {
            return static_cast<int8_t>(slot);
        }
        constant(C16_REG_ADDR, spill_address(slot));
        insn(C16_OP_LD, 0, C16_REG_ADDR, scratch);
        return scratch;
    }

    // Where the result of an operation writing slot should be computed.
    int8_t result_register(uint32_t slot) {
        note_slot(slot);
        return in_register(slot) ? static_cast<int8_t>(slot) : C16_REG_SCRATCH_A;
    }

    // Put it back, if it did not land in a register of its own.
    void commit(uint32_t slot, int8_t reg) {
        if (in_register(slot)) {
            return;
        }
        constant(C16_REG_ADDR, spill_address(slot));
        insn(C16_OP_ST, reg, C16_REG_ADDR, 0);
    }

    bool check_slot(uint32_t slot) {
        if (slot < C16_MAX_SLOTS) {
            return true;
        }
        fail(std::format("expression needs more than {} stack slots, simplify it",
                         C16_MAX_SLOTS));
        return false;
    }

    // ------------------------------------------------- comparison helpers

    // cpu16 has no "set on condition", but sub writes a borrow into the carry
    // flag and adc reads it, so "0 + 0 + carry" turns any unsigned comparison
    // into a 0/1 value in three instructions.  dst may be either operand: by
    // the time it is written both have already been consumed.
    void set_from_carry(int8_t dst) {
        insn(C16_OP_IMM, 0, 0, dst);
        insn(C16_OP_ADC, dst, dst, dst);
    }

    void emit_lt(int8_t a, int8_t b, int8_t dst) {
        insn(C16_OP_SUB, a, b, C16_REG_ADDR);   // carry = a < b, unsigned
        set_from_carry(dst);
    }

    void invert(int8_t dst) {
        insn(C16_OP_IMM, 1, 0, C16_REG_ADDR);
        insn(C16_OP_XOR, dst, C16_REG_ADDR, dst);
    }

    void emit_eq(int8_t a, int8_t b, int8_t dst) {
        insn(C16_OP_SUB, a, b, C16_REG_ADDR);       // r7 = a - b
        insn(C16_OP_IMM, 1, 0, dst);
        insn(C16_OP_SUB, C16_REG_ADDR, dst, C16_REG_ADDR);   // carry = (a-b) < 1
        set_from_carry(dst);
    }

    void emit_ne(int8_t a, int8_t b, int8_t dst) {
        insn(C16_OP_SUB, a, b, dst);                // dst = a - b
        insn(C16_OP_IMM, 0, 0, C16_REG_ADDR);
        insn(C16_OP_SUB, C16_REG_ADDR, dst, C16_REG_ADDR);   // carry = 0 < (a-b)
        set_from_carry(dst);
    }

    // "x != 0", which is what && and || need of each side.
    void to_boolean(int8_t reg) {
        insn(C16_OP_IMM, 0, 0, C16_REG_ADDR);
        insn(C16_OP_SUB, C16_REG_ADDR, reg, C16_REG_ADDR);
        set_from_carry(reg);
    }

    void emit_logical_not(int8_t reg, int8_t dst) {
        insn(C16_OP_IMM, 1, 0, C16_REG_ADDR);
        insn(C16_OP_SUB, reg, C16_REG_ADDR, C16_REG_ADDR);   // carry = reg < 1
        set_from_carry(dst);
    }

    // ---------------------------------------------------------- scopes

    struct binding {
        std::string_view name;
        uint32_t address;
    };

    void push_scope() { scope_mark_.push_back(bindings_.size()); }

    void pop_scope() {
        bindings_.resize(scope_mark_.back());
        scope_mark_.pop_back();
    }

    void declare(std::string_view name, uint32_t address) {
        bindings_.push_back(binding{name, address});
    }

    bool lookup(std::string_view name, uint32_t* address) const {
        for (size_t i = bindings_.size(); i-- > 0;) {
            if (bindings_[i].name == name) {
                *address = bindings_[i].address;
                return true;
            }
        }
        auto it = global_index_.find(name);
        if (it != global_index_.end()) {
            *address = globals_[it->second].address;
            return true;
        }
        return false;
    }

    // ---------------------------------------------------------- tokens

    std::string_view text(const c16_token& t) const {
        return std::string_view(source_.data() + t.off, t.len);
    }

    const c16_token& peek(uint32_t ahead = 0) const {
        uint32_t i = pos_ + ahead;
        return tokens_[i < end_ ? i : end_];
    }

    bool at(uint16_t kind) const { return peek().kind == kind; }

    bool accept(uint16_t kind) {
        if (!at(kind)) {
            return false;
        }
        pos_++;
        return true;
    }

    bool expect(uint16_t kind, const char* what) {
        if (accept(kind)) {
            return true;
        }
        fail(std::format("expected {} but found '{}'", what, std::string(text(peek()))));
        return false;
    }

    void fail(std::string message) {
        if (out_.error.failed) {
            return;
        }
        out_.error.failed = true;
        out_.error.line = peek().line;
        out_.error.token = pos_;
        out_.error.message = std::move(message);
    }

    bool failed() const { return out_.error.failed; }

    // ------------------------------------------------------- statements

    void statements() {
        while (!failed() && pos_ < end_ && !at(C16_TOK_RBRACE)) {
            statement();
        }
    }

    void block() {
        if (!expect(C16_TOK_LBRACE, "'{'")) {
            return;
        }
        push_scope();
        statements();
        pop_scope();
        expect(C16_TOK_RBRACE, "'}'");
    }

    void statement() {
        if (accept(C16_TOK_SEMI)) {
            return;
        }
        if (at(C16_TOK_LBRACE)) {
            block();
            return;
        }
        if (at(C16_TOK_INT)) {
            declaration();
            return;
        }
        if (at(C16_TOK_IF)) {
            if_statement();
            return;
        }
        if (at(C16_TOK_WHILE)) {
            while_statement();
            return;
        }
        if (at(C16_TOK_RETURN)) {
            return_statement();
            return;
        }
        if (at(C16_TOK_BREAK) || at(C16_TOK_CONTINUE)) {
            bool is_break = at(C16_TOK_BREAK);
            if (loops_.empty()) {
                fail(is_break ? "'break' outside a loop" : "'continue' outside a loop");
                return;
            }
            pos_++;
            jump(is_break ? loops_.back().brk : loops_.back().cont);
            expect(C16_TOK_SEMI, "';'");
            return;
        }
        // "name = expression;" or a bare expression, which is how a call is
        // written when its result is not wanted.
        if (at(C16_TOK_IDENT) && peek(1).kind == C16_TOK_ASSIGN) {
            std::string_view name = text(peek());
            uint32_t address = 0;
            if (!lookup(name, &address)) {
                fail(std::format("unknown variable '{}'", std::string(name)));
                return;
            }
            pos_ += 2;
            expression(0);
            if (failed()) {
                return;
            }
            note_use(address);
            int8_t reg = materialise(0, C16_REG_SCRATCH_A);
            int8_t home = var_register(address);
            if (home >= 0) {
                if (reg != home) {
                    insn(C16_OP_MOV, reg, 0, home);
                }
            }
            else {
                constant(C16_REG_ADDR, static_cast<uint8_t>(address));
                insn(C16_OP_ST, reg, C16_REG_ADDR, 0);
            }
            expect(C16_TOK_SEMI, "';'");
            return;
        }
        expression(0);
        expect(C16_TOK_SEMI, "';'");
    }

    void declaration() {
        pos_++;   // "int"
        if (!at(C16_TOK_IDENT)) {
            fail("expected a name after 'int'");
            return;
        }
        std::string_view name = text(peek());
        pos_++;
        uint32_t address = next_local_++;
        int8_t home = -1;
        if (accept(C16_TOK_ASSIGN)) {
            expression(0);
            if (failed()) {
                return;
            }
            note_use(address);
            home = var_register(address);
            int8_t reg = materialise(0, C16_REG_SCRATCH_A);
            if (home >= 0) {
                if (reg != home) {
                    insn(C16_OP_MOV, reg, 0, home);
                }
            }
            else {
                constant(C16_REG_ADDR, static_cast<uint8_t>(address));
                insn(C16_OP_ST, reg, C16_REG_ADDR, 0);
            }
        }
        else {
            // Without an initialiser the slot would still hold whatever the
            // last call to this function left in it, because every function
            // has one fixed frame rather than a fresh one per call.  That is
            // an undefined value, and undefined values make the language
            // impossible to check against a reference implementation, so
            // "int x;" means zero.  cpu16 clears a byte of memory in a single
            // instruction, so this costs one word beyond the address.
            note_use(address);
            home = var_register(address);
            if (home >= 0) {
                constant(home, 0);
            }
            else {
                constant(C16_REG_ADDR, static_cast<uint8_t>(address));
                insn(C16_OP_CL, 0, C16_REG_ADDR, 0);
            }
        }
        // A declaration only becomes visible after its own initialiser, so
        // "int x = x;" is an error rather than a read of itself.
        declare(name, address);
        expect(C16_TOK_SEMI, "';'");
    }

    void if_statement() {
        pos_++;
        if (!expect(C16_TOK_LPAREN, "'(' after 'if'")) {
            return;
        }
        expression(0);
        if (!expect(C16_TOK_RPAREN, "')'")) {
            return;
        }
        int8_t cond = materialise(0, C16_REG_SCRATCH_A);
        uint32_t otherwise = new_label();
        branch_if_zero(cond, otherwise);
        block();
        if (failed()) {
            return;
        }
        if (at(C16_TOK_ELSE)) {
            pos_++;
            uint32_t done = new_label();
            jump(done);
            label(otherwise);
            if (at(C16_TOK_IF)) {
                if_statement();
            }
            else {
                block();
            }
            label(done);
            return;
        }
        label(otherwise);
    }

    void while_statement() {
        uint32_t span_begin = pos_;
        pos_++;
        loop_depth_++;
        uint32_t top = new_label();
        uint32_t done = new_label();
        label(top);
        if (!expect(C16_TOK_LPAREN, "'(' after 'while'")) {
            return;
        }
        expression(0);
        if (!expect(C16_TOK_RPAREN, "')'")) {
            return;
        }
        int8_t cond = materialise(0, C16_REG_SCRATCH_A);
        branch_if_zero(cond, done);
        loops_.push_back(loop{done, top});
        block();
        loops_.pop_back();
        loop_depth_--;
        // The span the analysis pass widens intervals over: the whole "while",
        // condition included, because the back edge reaches both.
        if (analysing_) {
            loop_spans_.push_back(std::pair<uint32_t, uint32_t>(span_begin, pos_));
        }
        if (failed()) {
            return;
        }
        jump(top);
        label(done);
    }

    void return_statement() {
        pos_++;
        if (at(C16_TOK_SEMI)) {
            constant(0, 0);
        }
        else {
            expression(0);
            if (failed()) {
                return;
            }
            int8_t reg = materialise(0, C16_REG_SCRATCH_A);
            if (reg != 0) {
                insn(C16_OP_MOV, reg, 0, 0);
            }
        }
        emit_return();
        expect(C16_TOK_SEMI, "';'");
    }

    // The return value is always in r0.  main's is discarded - a program
    // reports through out(), and letting main's return also write out(0)
    // would quietly overwrite an out(0) the program set itself - so main just
    // falls into the epilogue.  Everything else reads the return address back
    // out of its own frame and branches to it.
    void emit_return() {
        if (self_ == 0) {
            jump(C16_EXIT_LABEL);
            return;
        }
        constant(C16_REG_ADDR, static_cast<uint8_t>(functions_[self_].frame));
        insn(C16_OP_LD, 0, C16_REG_ADDR, C16_REG_ADDR);
        insn(C16_OP_B, 0, C16_REG_ADDR, 0);
    }

    // The end of the program: copy whichever out() slots the program used
    // into r0..r6, where the testbench can see them, and then spin.  r7 is
    // not copied because it is holding the address of the spin.
    void epilogue() {
        label(C16_EXIT_LABEL);
        for (uint32_t i = 0; i < C16_OUT_SLOTS; i++) {
            if ((out_.out_mask & (1u << i)) == 0) {
                continue;
            }
            constant(C16_REG_ADDR, static_cast<uint8_t>(C16_OUT_BASE + i));
            insn(C16_OP_LD, 0, C16_REG_ADDR, static_cast<int8_t>(i));
        }
        uint32_t halt = new_label();
        la(C16_REG_ADDR, halt);
        label(halt);
        insn(C16_OP_B, 0, C16_REG_ADDR, 0);
    }

    // ------------------------------------------------------ expressions

    // One function per precedence level, lowest first.  "slot" is where the
    // value has to end up; a binary operator evaluates its left side into its
    // own slot and its right side into the next one up.
    void expression(uint32_t slot) { parse_oror(slot); }

    void parse_oror(uint32_t slot) {
        parse_andand(slot);
        while (!failed() && at(C16_TOK_OROR)) {
            pos_++;
            binary_rhs(slot, C16_TOK_OROR);
        }
    }

    void parse_andand(uint32_t slot) {
        parse_bitor(slot);
        while (!failed() && at(C16_TOK_ANDAND)) {
            pos_++;
            binary_rhs(slot, C16_TOK_ANDAND);
        }
    }

    void parse_bitor(uint32_t slot) {
        parse_bitxor(slot);
        while (!failed() && at(C16_TOK_PIPE)) {
            pos_++;
            binary_rhs(slot, C16_TOK_PIPE);
        }
    }

    void parse_bitxor(uint32_t slot) {
        parse_bitand(slot);
        while (!failed() && at(C16_TOK_CARET)) {
            pos_++;
            binary_rhs(slot, C16_TOK_CARET);
        }
    }

    void parse_bitand(uint32_t slot) {
        parse_equality(slot);
        while (!failed() && at(C16_TOK_AMP)) {
            pos_++;
            binary_rhs(slot, C16_TOK_AMP);
        }
    }

    void parse_equality(uint32_t slot) {
        parse_relational(slot);
        while (!failed() && (at(C16_TOK_EQ) || at(C16_TOK_NE))) {
            uint16_t op = peek().kind;
            pos_++;
            binary_rhs(slot, op);
        }
    }

    void parse_relational(uint32_t slot) {
        parse_shift(slot);
        while (!failed() && (at(C16_TOK_LT) || at(C16_TOK_LE) ||
                             at(C16_TOK_GT) || at(C16_TOK_GE))) {
            uint16_t op = peek().kind;
            pos_++;
            binary_rhs(slot, op);
        }
    }

    // The shift amount is an operand of the instruction word, not a register,
    // so it has to be a literal.  That is a real limit of the ISA and the
    // language says so rather than pretending otherwise.
    void parse_shift(uint32_t slot) {
        parse_additive(slot);
        while (!failed() && (at(C16_TOK_SHL) || at(C16_TOK_SHR))) {
            uint16_t op = peek().kind;
            pos_++;
            if (!at(C16_TOK_NUMBER) || peek().value < 0 || peek().value > 7) {
                fail("the right hand side of '<<' and '>>' must be a literal 0..7");
                return;
            }
            int8_t amount = static_cast<int8_t>(peek().value);
            pos_++;
            int8_t reg = materialise(slot, C16_REG_SCRATCH_A);
            int8_t dst = result_register(slot);
            insn(op == C16_TOK_SHL ? C16_OP_SHL : C16_OP_SHR, reg, amount, dst);
            commit(slot, dst);
        }
    }

    void parse_additive(uint32_t slot) {
        parse_multiplicative(slot);
        while (!failed() && (at(C16_TOK_PLUS) || at(C16_TOK_MINUS))) {
            uint16_t op = peek().kind;
            pos_++;
            binary_rhs(slot, op);
        }
    }

    void parse_multiplicative(uint32_t slot) {
        parse_unary(slot);
        while (!failed() && (at(C16_TOK_STAR) || at(C16_TOK_SLASH))) {
            uint16_t op = peek().kind;
            pos_++;
            binary_rhs(slot, op);
        }
    }

    // Evaluate the right hand side one slot up, then combine.
    void binary_rhs(uint32_t slot, uint16_t op) {
        if (!check_slot(slot + 1)) {
            return;
        }
        // The multiplicative level is the tightest binding one that can
        // appear on the right of any of these operators, except for the
        // operators at the same level, which are left associative; calling
        // the level above is exactly right for both.
        switch (op) {
        case C16_TOK_OROR:  parse_andand(slot + 1); break;
        case C16_TOK_ANDAND: parse_bitor(slot + 1); break;
        case C16_TOK_PIPE:  parse_bitxor(slot + 1); break;
        case C16_TOK_CARET: parse_bitand(slot + 1); break;
        case C16_TOK_AMP:   parse_equality(slot + 1); break;
        case C16_TOK_EQ:
        case C16_TOK_NE:    parse_relational(slot + 1); break;
        case C16_TOK_LT:
        case C16_TOK_LE:
        case C16_TOK_GT:
        case C16_TOK_GE:    parse_shift(slot + 1); break;
        case C16_TOK_PLUS:
        case C16_TOK_MINUS: parse_multiplicative(slot + 1); break;
        default:            parse_unary(slot + 1); break;
        }
        if (failed()) {
            return;
        }
        int8_t a = materialise(slot, C16_REG_SCRATCH_A);
        int8_t b = materialise(slot + 1, C16_REG_SCRATCH_B);
        int8_t dst = result_register(slot);
        switch (op) {
        case C16_TOK_PLUS:  insn(C16_OP_ADD, a, b, dst); break;
        case C16_TOK_MINUS: insn(C16_OP_SUB, a, b, dst); break;
        case C16_TOK_STAR:  insn(C16_OP_MUL, a, b, dst); break;
        case C16_TOK_SLASH: insn(C16_OP_DIV, a, b, dst); break;
        case C16_TOK_AMP:   insn(C16_OP_AND, a, b, dst); break;
        case C16_TOK_PIPE:  insn(C16_OP_OR,  a, b, dst); break;
        case C16_TOK_CARET: insn(C16_OP_XOR, a, b, dst); break;
        case C16_TOK_EQ:    emit_eq(a, b, dst); break;
        case C16_TOK_NE:    emit_ne(a, b, dst); break;
        case C16_TOK_LT:    emit_lt(a, b, dst); break;
        case C16_TOK_GT:    emit_lt(b, a, dst); break;
        case C16_TOK_GE:    emit_lt(a, b, dst); invert(dst); break;
        case C16_TOK_LE:    emit_lt(b, a, dst); invert(dst); break;
        case C16_TOK_ANDAND:
            to_boolean(a);
            to_boolean(b);
            insn(C16_OP_AND, a, b, dst);
            break;
        case C16_TOK_OROR:
            to_boolean(a);
            to_boolean(b);
            insn(C16_OP_OR, a, b, dst);
            break;
        default:
            fail("internal error: unknown binary operator");
            return;
        }
        commit(slot, dst);
    }

    void parse_unary(uint32_t slot) {
        if (at(C16_TOK_MINUS) || at(C16_TOK_TILDE) || at(C16_TOK_BANG) || at(C16_TOK_PLUS)) {
            uint16_t op = peek().kind;
            pos_++;
            parse_unary(slot);
            if (failed()) {
                return;
            }
            if (op == C16_TOK_PLUS) {
                return;
            }
            int8_t reg = materialise(slot, C16_REG_SCRATCH_A);
            int8_t dst = result_register(slot);
            if (op == C16_TOK_MINUS) {
                insn(C16_OP_NEG, reg, 0, dst);
            }
            else if (op == C16_TOK_TILDE) {
                insn(C16_OP_NOT, reg, 0, dst);
            }
            else {
                emit_logical_not(reg, dst);
            }
            commit(slot, dst);
            return;
        }
        parse_primary(slot);
    }

    void parse_primary(uint32_t slot) {
        if (accept(C16_TOK_LPAREN)) {
            expression(slot);
            expect(C16_TOK_RPAREN, "')'");
            return;
        }
        if (at(C16_TOK_NUMBER)) {
            int32_t v = peek().value;
            if (v < 0 || v > 255) {
                fail(std::format("the literal {} does not fit in cpu16's 8 bit data", v));
                return;
            }
            pos_++;
            int8_t dst = result_register(slot);
            constant(dst, static_cast<uint8_t>(v));
            commit(slot, dst);
            return;
        }
        if (!at(C16_TOK_IDENT)) {
            fail(std::format("expected a value but found '{}'", std::string(text(peek()))));
            return;
        }
        std::string_view name = text(peek());
        if (peek(1).kind == C16_TOK_LPAREN) {
            pos_ += 2;
            call(slot, name);
            return;
        }
        uint32_t address = 0;
        if (!lookup(name, &address)) {
            fail(std::format("unknown variable '{}'", std::string(name)));
            return;
        }
        pos_++;
        note_use(address);
        int8_t dst = result_register(slot);
        int8_t home = var_register(address);
        if (home >= 0) {
            insn(C16_OP_MOV, home, 0, dst);
        }
        else {
            constant(C16_REG_ADDR, static_cast<uint8_t>(address));
            insn(C16_OP_LD, 0, C16_REG_ADDR, dst);
        }
        commit(slot, dst);
    }

    // ------------------------------------------------------------ calls

    // Gather the argument list into slots starting at first_slot.  Returns
    // the count, or leaves the error set.
    uint32_t arguments(uint32_t first_slot, uint32_t limit) {
        uint32_t n = 0;
        if (accept(C16_TOK_RPAREN)) {
            return 0;
        }
        for (;;) {
            if (n >= limit || !check_slot(first_slot + n)) {
                if (n >= limit) {
                    fail("too many arguments");
                }
                return n;
            }
            expression(first_slot + n);
            n++;
            if (failed()) {
                return n;
            }
            if (accept(C16_TOK_COMMA)) {
                continue;
            }
            expect(C16_TOK_RPAREN, "')' or ','");
            return n;
        }
    }

    void call(uint32_t slot, std::string_view name) {
        if (name == "peek" || name == "poke" || name == "out") {
            // peek and poke name an address computed at run time, and nothing
            // stops it being a promoted variable's frame byte, which is stale
            // by construction.  out() writes a fixed address of its own.
            if (name != "out") {
                saw_raw_memory_ = true;
            }
            builtin(slot, name);
            return;
        }
        // A call clobbers the callee's registers, and this stage has no
        // caller-save, so a function that makes one keeps its variables in
        // memory.
        saw_call_ = true;
        auto found = function_index_.find(name);
        if (found == function_index_.end()) {
            fail(std::format("unknown function '{}'", std::string(name)));
            return;
        }
        uint32_t callee = found->second;
        const c16_function& f = functions_[callee];
        uint32_t n = arguments(slot, f.nparams == 0 ? 1u : f.nparams);
        if (failed()) {
            return;
        }
        if (n != f.nparams) {
            fail(std::format("'{}' takes {} argument(s), {} given",
                             std::string(name), f.nparams, n));
            return;
        }
        out_.calls.push_back(callee);

        // A call clobbers everything, so the operands of the expression this
        // call sits inside have to be put somewhere first.  They are spilled
        // *after* the arguments are evaluated, not before: an argument may
        // contain a call of its own, and that inner call has to find those
        // operands still in their registers so that it can save and restore
        // them itself.
        uint32_t saved = std::min<uint32_t>(slot, C16_REG_SLOTS);
        for (uint32_t s = 0; s < saved; s++) {
            constant(C16_REG_ADDR, spill_address(s));
            insn(C16_OP_ST, static_cast<int8_t>(s), C16_REG_ADDR, 0);
        }
        for (uint32_t i = 0; i < n; i++) {
            int8_t reg = materialise(slot + i, C16_REG_SCRATCH_B);
            constant(C16_REG_ADDR, static_cast<uint8_t>(f.frame + 1 + i));
            insn(C16_OP_ST, reg, C16_REG_ADDR, 0);
        }
        uint32_t back = new_label();
        la(C16_REG_SCRATCH_B, back);
        constant(C16_REG_ADDR, static_cast<uint8_t>(f.frame));
        insn(C16_OP_ST, C16_REG_SCRATCH_B, C16_REG_ADDR, 0);
        la(C16_REG_ADDR, C16_FUNCTION_TAG | callee);
        insn(C16_OP_B, 0, C16_REG_ADDR, 0);
        label(back);

        // The result comes back in r0, which is also slot 0, so when this
        // call is the whole expression there is nothing at all to do.
        if (slot == 0) {
            return;
        }
        constant(C16_REG_ADDR, spill_address(slot));
        insn(C16_OP_ST, 0, C16_REG_ADDR, 0);
        for (uint32_t s = 0; s < saved; s++) {
            constant(C16_REG_ADDR, spill_address(s));
            insn(C16_OP_LD, 0, C16_REG_ADDR, static_cast<int8_t>(s));
        }
        if (in_register(slot)) {
            constant(C16_REG_ADDR, spill_address(slot));
            insn(C16_OP_LD, 0, C16_REG_ADDR, static_cast<int8_t>(slot));
        }
    }

    void builtin(uint32_t slot, std::string_view name) {
        if (name == "peek") {
            uint32_t n = arguments(slot, 1);
            if (failed()) {
                return;
            }
            if (n != 1) {
                fail("peek() takes one argument, the data memory address");
                return;
            }
            int8_t addr = materialise(slot, C16_REG_SCRATCH_A);
            int8_t dst = result_register(slot);
            insn(C16_OP_LD, 0, addr, dst);
            commit(slot, dst);
            return;
        }
        if (name == "poke") {
            if (!check_slot(slot + 1)) {
                return;
            }
            uint32_t n = arguments(slot, 2);
            if (failed()) {
                return;
            }
            if (n != 2) {
                fail("poke() takes two arguments, an address and a value");
                return;
            }
            int8_t addr = materialise(slot, C16_REG_SCRATCH_A);
            int8_t value = materialise(slot + 1, C16_REG_SCRATCH_B);
            insn(C16_OP_ST, value, addr, 0);
            int8_t dst = result_register(slot);
            insn(C16_OP_IMM, 0, 0, dst);
            commit(slot, dst);
            return;
        }
        // out(index, value): index has to be a literal because the epilogue
        // has to know at compile time which registers it must fill.
        if (!at(C16_TOK_NUMBER) || peek().value < 0 ||
            peek().value >= static_cast<int32_t>(C16_OUT_SLOTS)) {
            fail(std::format("the first argument of out() must be a literal 0..{}",
                             C16_OUT_SLOTS - 1));
            return;
        }
        uint32_t index = static_cast<uint32_t>(peek().value);
        pos_++;
        if (!expect(C16_TOK_COMMA, "',' after the out() slot number")) {
            return;
        }
        expression(slot);
        if (failed()) {
            return;
        }
        expect(C16_TOK_RPAREN, "')'");
        if (failed()) {
            return;
        }
        int8_t value = materialise(slot, C16_REG_SCRATCH_A);
        constant(C16_REG_ADDR, static_cast<uint8_t>(C16_OUT_BASE + index));
        insn(C16_OP_ST, value, C16_REG_ADDR, 0);
        out_.out_mask |= 1u << index;
        int8_t dst = result_register(slot);
        insn(C16_OP_IMM, 0, 0, dst);
        commit(slot, dst);
    }

    struct loop {
        uint32_t brk;
        uint32_t cont;
    };

    const std::vector<char>& source_;
    const std::vector<c16_token>& tokens_;
    const std::vector<c16_function>& functions_;
    const std::unordered_map<std::string_view, uint32_t>& function_index_;
    const std::vector<c16_global>& globals_;
    const std::unordered_map<std::string_view, uint32_t>& global_index_;
    uint32_t self_ = 0;
    uint32_t pos_ = 0;
    uint32_t end_ = 0;
    uint32_t next_local_ = 0;
    std::vector<binding> bindings_;
    std::vector<size_t> scope_mark_;
    std::vector<loop> loops_;
    int addr_cache_ = -1;   // the constant r7 is known to hold, or -1

    // The variables-in-registers stage.  docs/c16.md, "Variables in registers".
    bool allocate_ = true;          // is the stage enabled at all
    bool analysing_ = false;        // pass 1: parse, record, emit nothing
    uint32_t max_slot_ = 0;         // deepest expression stack slot reached
    uint32_t loop_depth_ = 0;       // how many "while"s enclose the parser
    bool saw_call_ = false;         // a call clobbers a promoted variable
    bool saw_raw_memory_ = false;   // peek/poke can name a promoted frame byte
    std::vector<c16_var_use> uses_;
    std::vector<std::pair<uint32_t, uint32_t>> loop_spans_;
    std::vector<int8_t> allocated_; // address -> register, or empty for none
    c16_lowered out_;
};

#endif  // C16_COMPILER_HPP
