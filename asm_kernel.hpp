#ifndef ASM_KERNEL_HPP
#define ASM_KERNEL_HPP

// The per line half of the assembler.
//
// Everything in this header is written so that the *same* source compiles as
// ordinary C++ and as HIP device code: no std::string, no containers, no
// exceptions, no iostreams, and no pointers into anything but one flat input
// buffer.  That is deliberate.  The serial backend, the std::thread backend
// and the GPU backend all call these functions, so "the three paths produce
// identical bytes" is a property of the code rather than something that has
// to be re-verified by hand every time the ISA changes.  The equivalence test
// still checks it, because a shared implementation can still be driven wrong.
//
// The split is:
//
//   classify_line()  lex + parse one source line, independent of every other
//                    line.  Embarrassingly parallel.
//   (host, serial)   place addresses, build the label table, resolve "la".
//                    This is the only stage that has to see the whole program
//                    in order, and it is a scan, not real work.
//   encode()         turn one statement into its instruction words, and
//                    write_words() place them at an offset computed from the
//                    statement's address.  Also embarrassingly parallel,
//                    including the formatting of the text output.

#include <cstddef>
#include <cstdint>

#if defined(__HIPCC__) || defined(__CUDACC__)
#define ASM_HD __host__ __device__
#else
#define ASM_HD
#endif

// A slice of the input buffer.  Tokens are never copied out of it.
struct asm_span {
    uint32_t off;
    uint32_t len;
};

enum : uint32_t {
    ASM_MAX_WORDS = 10,   // the longest "la" expansion, cpu8's
    ASM_MAX_ARGS = 5,     // gpu16's Arg0, Arg1, Arg2, Arg3 and Mod
    ASM_MAX_TOKENS = 5,   // gpu16's "<op> <dst> <src0> <src1> <src2>"
};

// What a line does with a label, if anything.  "la" is the pseudo
// instruction every ISA here has; gpu16 additionally lets a label stand in
// for the immediate of the instructions that take a code address, which is
// the same two pass machinery with a different encoding at the end of it.
enum : uint8_t {
    ASM_LABEL_NONE = 0,
    ASM_LABEL_LA,     // the "la" pseudo instruction
    ASM_LABEL_IMM,    // a label used as an instruction's immediate operand
};

// Errors that one line can diagnose on its own, in the order the original
// single threaded assembler checked them, followed by the ones that need the
// label table and therefore belong to the serial pass.
enum : uint8_t {
    ASM_OK = 0,
    ASM_ERR_LA_TOKENS,
    ASM_ERR_LA_DST,
    ASM_ERR_TOKENS,
    ASM_ERR_OPCODE,
    ASM_ERR_ARG,
    ASM_ERR_ARG_RANGE0,
    ASM_ERR_ARG_RANGE1,
    ASM_ERR_ARG_RANGE2,
    ASM_ERR_LABEL_DUP,
    ASM_ERR_TOO_BIG,
    ASM_ERR_UNKNOWN_LABEL,
    ASM_ERR_NO_SCRATCH,
    ASM_ERR_SCRATCH_IS_DST,
    // The rest belong to an ISA whose operands are not all the same kind,
    // which so far means gpu16: an operand can be the wrong register file, a
    // register the file is not big enough for, an immediate that does not
    // fit, a misaligned VGPR quad, or a label somewhere a label means
    // nothing.
    ASM_ERR_OPERANDS,
    ASM_ERR_ARG_KIND,
    ASM_ERR_REG_RANGE,
    ASM_ERR_IMM_RANGE,
    ASM_ERR_MOD_RANGE,
    ASM_ERR_QUAD_ALIGN,
    ASM_ERR_LABEL_KIND,
    ASM_ERR_BRANCH_RANGE,
};

// The result of lexing and parsing one line, kept deliberately small: the
// serial pass and the encode pass both stream the whole array, so every byte
// here is paid for once per line at memory speed.  Anything only the cold
// paths need - the text of a token for an error message, the names of the
// labels a line defines - is recovered by re-lexing that one line, which
// costs nothing because it happens on a handful of lines rather than all of
// them.
//
// arg[] is only meaningful when error == ASM_OK; an operand that failed to
// parse or did not fit is reported from its source text instead.  On the
// errors that name one operand out of several, arg[0] carries which operand
// it was and arg[1] how many the instruction wanted, so that the message can
// be built without re-deciding anything the parse already decided.
struct asm_line {
    uint32_t nlabels;     // how many "label:" definitions the line opens with
    uint32_t ntokens;     // how many tokens follow them
    asm_span name;        // the label operand, when label_use is not NONE
    int32_t  arg[ASM_MAX_ARGS];
    uint8_t  opcode;      // the encoded opcode value, not an index
    uint8_t  label_use;   // ASM_LABEL_NONE, _LA or _IMM
    uint8_t  error;
    uint8_t  pad;
};

// One line that actually assembles to something, after the scan has given it
// an address and resolved its label.
struct asm_statement {
    uint32_t line_index;
    uint32_t address;     // in instruction words
    int32_t  target;      // resolved label address, when label_use is not NONE
    int32_t  arg[ASM_MAX_ARGS];
    uint8_t  opcode;
    uint8_t  label_use;
    uint8_t  pad[2];
};

// How the words are laid out in the output buffer.
struct asm_format {
    uint8_t hex;                       // text instead of raw little endian
    uint8_t word_bytes;                // 1 for cpu8, 2 for cpu16, 4 for gpu16
    char    sep;                       // ',' or '\n', hex only
    char    pad;
};

ASM_HD inline uint32_t asm_bytes_per_word(asm_format f) {
    return f.hex ? 2u * f.word_bytes + 1u : f.word_bytes;
}

// ---------------------------------------------------------------- lexing

// The whitespace std::istringstream's >> skips, so that a stray CR from a
// CRLF file keeps being harmless.
ASM_HD inline bool asm_is_space(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

ASM_HD inline bool asm_is_digit(char c) {
    return c >= '0' && c <= '9';
}

// Compare a token against a literal.
ASM_HD inline bool asm_tok_is(const char* s, uint32_t len, const char* lit) {
    uint32_t i = 0;
    for (; lit[i] != '\0'; i++) {
        if (i >= len || s[i] != lit[i]) {
            return false;
        }
    }
    return i == len;
}

// A token ending in ':' defines a label.  ":" alone does not.
ASM_HD inline bool asm_is_label_definition(const char* s, uint32_t len) {
    return len > 1 && s[len - 1] == ':';
}

// Everything before the first '#'.
ASM_HD inline uint32_t asm_code_length(const char* s, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        if (s[i] == '#') {
            return i;
        }
    }
    return len;
}

// What separates two tokens.  gpu16's syntax is the one documented in
// docs/gpu_isa.md section 4.1, "op dst, src0, src1, src2", so for that ISA a
// comma separates operands exactly as whitespace does; for cpu8 and cpu16 it
// does not, and a comma stays part of whatever token it appears in, which is
// what those two assemblers have always done.
ASM_HD inline bool asm_is_separator(char c, bool commas) {
    return asm_is_space(c) || (commas && c == ',');
}

// Step to the next separated token.  Returns false at end of line.
ASM_HD inline bool asm_next_token(const char* s, uint32_t len, uint32_t* pos, asm_span* out,
                                  bool commas = false) {
    uint32_t i = *pos;
    while (i < len && asm_is_separator(s[i], commas)) {
        i++;
    }
    if (i >= len) {
        *pos = i;
        return false;
    }
    uint32_t begin = i;
    while (i < len && !asm_is_separator(s[i], commas)) {
        i++;
    }
    out->off = begin;
    out->len = i - begin;
    *pos = i;
    return true;
}

// std::stoi's behaviour, without the exceptions: an optional sign, at least
// one decimal digit, trailing junk ignored ("12abc" is 12), and anything that
// does not fit in an int rejected the way stoi's out_of_range would be.
ASM_HD inline bool asm_parse_int(const char* s, uint32_t len, int32_t* out) {
    uint32_t i = 0;
    while (i < len && asm_is_space(s[i])) {
        i++;
    }
    bool negative = false;
    if (i < len && (s[i] == '+' || s[i] == '-')) {
        negative = s[i] == '-';
        i++;
    }
    if (i >= len || !asm_is_digit(s[i])) {
        return false;
    }
    int64_t value = 0;
    for (; i < len && asm_is_digit(s[i]); i++) {
        value = value * 10 + (s[i] - '0');
        if (value > 4294967296LL) {
            value = 4294967296LL;  // saturate, the range check below rejects it
        }
    }
    int64_t signed_value = negative ? -value : value;
    if (signed_value > 2147483647LL || signed_value < -2147483648LL) {
        return false;
    }
    *out = static_cast<int32_t>(signed_value);
    return true;
}

// r0..r7, shared by both ISAs.
ASM_HD inline bool asm_register(const char* s, uint32_t len, int32_t* out) {
    if (len == 2 && s[0] == 'r' && s[1] >= '0' && s[1] <= '7') {
        *out = s[1] - '0';
        return true;
    }
    return false;
}

// asm_parse_int plus hexadecimal, because a 16 bit immediate is far more
// often written 0xabcd than 43981.  Unlike asm_parse_int this one rejects
// trailing junk: "0x1g" is not a number, and an ISA that has labels needs to
// be able to tell a number apart from a name rather than half accept one.
ASM_HD inline bool asm_parse_number(const char* s, uint32_t len, int32_t* out) {
    uint32_t i = 0;
    bool negative = false;
    if (i < len && (s[i] == '+' || s[i] == '-')) {
        negative = s[i] == '-';
        i++;
    }
    int64_t value = 0;
    bool any = false;
    if (i + 1 < len && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
        i += 2;
        for (; i < len; i++) {
            int32_t digit;
            if (asm_is_digit(s[i]))                 { digit = s[i] - '0'; }
            else if (s[i] >= 'a' && s[i] <= 'f')    { digit = s[i] - 'a' + 10; }
            else if (s[i] >= 'A' && s[i] <= 'F')    { digit = s[i] - 'A' + 10; }
            else                                    { return false; }
            value = value * 16 + digit;
            any = true;
            if (value > 4294967296LL) {
                return false;
            }
        }
    }
    else {
        for (; i < len; i++) {
            if (!asm_is_digit(s[i])) {
                return false;
            }
            value = value * 10 + (s[i] - '0');
            any = true;
            if (value > 4294967296LL) {
                return false;
            }
        }
    }
    if (!any) {
        return false;
    }
    int64_t signed_value = negative ? -value : value;
    if (signed_value > 4294967295LL || signed_value < -2147483648LL) {
        return false;
    }
    *out = static_cast<int32_t>(signed_value);
    return true;
}

// ---------------------------------------------------------------- cpu8

// The operand parse cpu8 and cpu16 share: a fixed number of tokens, every
// operand the same kind, and every operand three bits wide.  gpu16 has none
// of those three properties and brings its own parse.
template <class ISA>
ASM_HD inline uint8_t asm_parse_fixed(const char* s, const asm_span* t, uint32_t ntokens,
                                      asm_line* out) {
    if (ntokens != ISA::insn_tokens) {
        return ASM_ERR_TOKENS;
    }
    if (!ISA::opcode(s + t[0].off, t[0].len, &out->opcode)) {
        return ASM_ERR_OPCODE;
    }
    int32_t parsed[3] = {0, 0, 0};
    for (uint32_t i = 0; i < ISA::nargs; i++) {
        if (!ISA::arg(s + t[1 + i].off, t[1 + i].len, &parsed[i])) {
            return ASM_ERR_ARG;
        }
    }
    for (uint32_t i = 0; i < ISA::nargs; i++) {
        if (parsed[i] < 0 || parsed[i] > 7) {
            return static_cast<uint8_t>(ASM_ERR_ARG_RANGE0 + i);
        }
    }
    for (uint32_t i = 0; i < ISA::nargs; i++) {
        out->arg[i] = parsed[i];
    }
    return ASM_OK;
}

// The 8 bit ISA.  Instruction word: opcode in the top 5 bits, one 3 bit
// operand below it.
struct asm_cpu8 {
    static constexpr const char* reg_range_text = "this machine has sixteen of each file";
    static constexpr const char* imm_range_text = "does not fit in 16 bits";
    static constexpr const char* branch_range_text = "is too far away to encode in 16 bits";
    static constexpr const char* tool = "asm";
    static constexpr uint32_t word_bytes = 1;
    // Which ISA this is, for the backends that dispatch at run time
    // rather than at compile time - asm_hip.hip is compiled once and
    // cannot be a template across the boundary.
    static constexpr int isa_tag = 8;
    static constexpr uint32_t la_words = 10;
    static constexpr uint32_t insn_tokens = 2;   // "<op> <arg>"
    static constexpr uint32_t nargs = 1;
    static constexpr bool has_scratch = true;    // "la" needs set_src1_dst1
    static constexpr bool comma_separated = false;
    static constexpr bool typed_operands = false;
    static constexpr uint32_t address_limit = 255;

    ASM_HD static bool opcode(const char* s, uint32_t n, uint8_t* out) {
        switch (n) {
        case 1:
            if (asm_tok_is(s, n, "b"))                { *out = 18; return true; }
            break;
        case 2:
            if (asm_tok_is(s, n, "or"))               { *out =  1; return true; }
            if (asm_tok_is(s, n, "ld"))               { *out = 24; return true; }
            if (asm_tok_is(s, n, "st"))               { *out = 25; return true; }
            if (asm_tok_is(s, n, "cl"))               { *out = 26; return true; }
            break;
        case 3:
            if (asm_tok_is(s, n, "and"))              { *out =  0; return true; }
            if (asm_tok_is(s, n, "not"))              { *out =  2; return true; }
            if (asm_tok_is(s, n, "xor"))              { *out =  3; return true; }
            if (asm_tok_is(s, n, "add"))              { *out =  4; return true; }
            if (asm_tok_is(s, n, "sub"))              { *out =  5; return true; }
            if (asm_tok_is(s, n, "neg"))              { *out =  6; return true; }
            if (asm_tok_is(s, n, "mul"))              { *out =  7; return true; }
            if (asm_tok_is(s, n, "div"))              { *out =  8; return true; }
            if (asm_tok_is(s, n, "mov"))              { *out =  9; return true; }
            if (asm_tok_is(s, n, "imm"))              { *out = 11; return true; }
            if (asm_tok_is(s, n, "shl"))              { *out = 12; return true; }
            if (asm_tok_is(s, n, "shr"))              { *out = 13; return true; }
            break;
        case 4:
            if (asm_tok_is(s, n, "mov0"))             { *out = 10; return true; }
            if (asm_tok_is(s, n, "swap"))             { *out = 27; return true; }
            if (asm_tok_is(s, n, "ld_p"))             { *out = 28; return true; }
            if (asm_tok_is(s, n, "st_p"))             { *out = 29; return true; }
            break;
        case 11:
            if (asm_tok_is(s, n, "condition_z"))      { *out = 15; return true; }
            if (asm_tok_is(s, n, "condition_1"))      { *out = 18; return true; }
            break;
        case 12:
            if (asm_tok_is(s, n, "condition_nz"))     { *out = 14; return true; }
            if (asm_tok_is(s, n, "condition_lz"))     { *out = 16; return true; }
            if (asm_tok_is(s, n, "condition_gz"))     { *out = 17; return true; }
            if (asm_tok_is(s, n, "set_b_target"))     { *out = 19; return true; }
            break;
        case 13:
            if (asm_tok_is(s, n, "set_src1_dst1"))    { *out = 31; return true; }
            break;
        case 16:
            if (asm_tok_is(s, n, "set_data_address")) { *out = 20; return true; }
            break;
        default:
            break;
        }
        return false;
    }

    ASM_HD static bool arg(const char* s, uint32_t n, int32_t* out) {
        if (asm_register(s, n, out)) {
            return true;
        }
        if (asm_tok_is(s, n, "condition_1")) { *out = 0; return true; }
        if (asm_tok_is(s, n, "b"))           { *out = 1; return true; }
        return asm_parse_int(s, n, out);
    }

    // The opcode that hands "la" its scratch register.
    ASM_HD static bool is_scratch_setter(uint8_t op) { return op == 31; }

    ASM_HD static bool la_dst(const char* s, uint32_t n, int32_t* out) {
        return asm_register(s, n, out);
    }

    ASM_HD static uint8_t parse(const char* s, uint32_t, const asm_span* t,
                                uint32_t ntokens, asm_line* out) {
        return asm_parse_fixed<asm_cpu8>(s, t, ntokens, out);
    }

    // No immediate can be out of range once a label is known: "la" builds the
    // address out of 3 bit pieces and the program cannot be longer than the
    // program memory the scan already checked.
    ASM_HD static uint8_t check_resolved(const asm_line&, uint32_t, int32_t) {
        return ASM_OK;
    }

    ASM_HD static uint32_t encode(const asm_statement& s, uint32_t* words) {
        if (s.label_use != ASM_LABEL_LA) {
            words[0] = static_cast<uint32_t>((s.opcode << 3) | s.arg[0]);
            return 1;
        }
        // The 8 bit CPU moves 3 bits of immediate at a time and has no
        // or-with-immediate, so a label address is folded into the
        // destination three bits at a time through the src1/dst1 scratch.
        int32_t dst = s.arg[0];
        int32_t t = s.target;
        words[0] = static_cast<uint32_t>((11 << 3) | ((t >> 6) & 3));  // imm
        words[1] = static_cast<uint32_t>((12 << 3) | 3);               // shl 3
        words[2] = static_cast<uint32_t>(( 9 << 3) | dst);             // mov
        words[3] = static_cast<uint32_t>((11 << 3) | ((t >> 3) & 7));  // imm
        words[4] = static_cast<uint32_t>(( 1 << 3) | dst);             // or
        words[5] = static_cast<uint32_t>((10 << 3) | dst);             // mov0
        words[6] = static_cast<uint32_t>((12 << 3) | 3);               // shl 3
        words[7] = static_cast<uint32_t>(( 9 << 3) | dst);             // mov
        words[8] = static_cast<uint32_t>((11 << 3) | (t & 7));         // imm
        words[9] = static_cast<uint32_t>(( 1 << 3) | dst);             // or
        return 10;
    }
};

// ---------------------------------------------------------------- cpu16

// The 16 bit ISA.  Instruction word: opcode in the top 7 bits, three 3 bit
// operands below it.
struct asm_cpu16 {
    static constexpr const char* reg_range_text = "this machine has sixteen of each file";
    static constexpr const char* imm_range_text = "does not fit in 16 bits";
    static constexpr const char* branch_range_text = "is too far away to encode in 16 bits";
    static constexpr const char* tool = "asm16";
    static constexpr uint32_t word_bytes = 2;
    // Which ISA this is, for the backends that dispatch at run time
    // rather than at compile time - asm_hip.hip is compiled once and
    // cannot be a template across the boundary.
    static constexpr int isa_tag = 16;
    static constexpr uint32_t la_words = 3;
    static constexpr uint32_t insn_tokens = 4;   // "<op> <arg0> <arg1> <arg2>"
    static constexpr uint32_t nargs = 3;
    static constexpr bool has_scratch = false;
    static constexpr bool comma_separated = false;
    static constexpr bool typed_operands = false;
    static constexpr uint32_t address_limit = 255;

    ASM_HD static bool opcode(const char* s, uint32_t n, uint8_t* out) {
        switch (n) {
        case 1:
            if (asm_tok_is(s, n, "b"))      { *out = 34; return true; }
            break;
        case 2:
            if (asm_tok_is(s, n, "or"))     { *out =  1; return true; }
            if (asm_tok_is(s, n, "bz"))     { *out = 33; return true; }
            if (asm_tok_is(s, n, "ld"))     { *out = 64; return true; }
            if (asm_tok_is(s, n, "st"))     { *out = 65; return true; }
            if (asm_tok_is(s, n, "cl"))     { *out = 66; return true; }
            break;
        case 3:
            if (asm_tok_is(s, n, "and"))    { *out =  0; return true; }
            if (asm_tok_is(s, n, "not"))    { *out =  2; return true; }
            if (asm_tok_is(s, n, "xor"))    { *out =  3; return true; }
            if (asm_tok_is(s, n, "add"))    { *out =  4; return true; }
            if (asm_tok_is(s, n, "adc"))    { *out =  5; return true; }
            if (asm_tok_is(s, n, "sub"))    { *out =  6; return true; }
            if (asm_tok_is(s, n, "sbb"))    { *out =  7; return true; }
            if (asm_tok_is(s, n, "neg"))    { *out =  8; return true; }
            if (asm_tok_is(s, n, "mul"))    { *out =  9; return true; }
            if (asm_tok_is(s, n, "div"))    { *out = 10; return true; }
            if (asm_tok_is(s, n, "mov"))    { *out = 11; return true; }
            if (asm_tok_is(s, n, "imm"))    { *out = 12; return true; }
            if (asm_tok_is(s, n, "shl"))    { *out = 14; return true; }
            if (asm_tok_is(s, n, "shr"))    { *out = 15; return true; }
            if (asm_tok_is(s, n, "srl"))    { *out = 16; return true; }
            if (asm_tok_is(s, n, "srr"))    { *out = 17; return true; }
            if (asm_tok_is(s, n, "sar"))    { *out = 18; return true; }
            if (asm_tok_is(s, n, "bnz"))    { *out = 32; return true; }
            if (asm_tok_is(s, n, "blz"))    { *out = 35; return true; }
            if (asm_tok_is(s, n, "bgz"))    { *out = 36; return true; }
            break;
        case 4:
            if (asm_tok_is(s, n, "swap"))   { *out = 67; return true; }
            if (asm_tok_is(s, n, "ld_p"))   { *out = 68; return true; }
            if (asm_tok_is(s, n, "st_p"))   { *out = 69; return true; }
            break;
        case 5:
            if (asm_tok_is(s, n, "imm_s"))  { *out = 13; return true; }
            break;
        case 6:
            if (asm_tok_is(s, n, "add_ip")) { *out = 19; return true; }
            break;
        default:
            break;
        }
        return false;
    }

    ASM_HD static bool arg(const char* s, uint32_t n, int32_t* out) {
        if (asm_register(s, n, out)) {
            return true;
        }
        return asm_parse_int(s, n, out);
    }

    ASM_HD static bool is_scratch_setter(uint8_t) { return false; }

    ASM_HD static bool la_dst(const char* s, uint32_t n, int32_t* out) {
        return asm_register(s, n, out);
    }

    ASM_HD static uint8_t parse(const char* s, uint32_t, const asm_span* t,
                                uint32_t ntokens, asm_line* out) {
        return asm_parse_fixed<asm_cpu16>(s, t, ntokens, out);
    }

    ASM_HD static uint8_t check_resolved(const asm_line&, uint32_t, int32_t) {
        return ASM_OK;
    }

    ASM_HD static uint32_t encode(const asm_statement& s, uint32_t* words) {
        if (s.label_use != ASM_LABEL_LA) {
            words[0] = static_cast<uint32_t>((s.opcode << 9) | (s.arg[0] << 6) |
                                             (s.arg[1] << 3) | s.arg[2]);
            return 1;
        }
        int32_t dst = s.arg[0];
        int32_t t = s.target;
        words[0] = static_cast<uint32_t>((12 << 9) | (((t >> 6) & 3) << 6) | (6 << 3) | dst);
        words[1] = static_cast<uint32_t>((13 << 9) | (((t >> 3) & 7) << 6) | (3 << 3) | dst);
        words[2] = static_cast<uint32_t>((13 << 9) | (( t       & 7) << 6) | (0 << 3) | dst);
        return 3;
    }
};

// ---------------------------------------------------------------- gpu16

// The gpu16 ISA of docs/gpu_isa.md, as committed: a 32 bit word laid out
// 8 / 4 / 4 / 4 / 4 / 8 (section 4.1),
//
//   |1f .. 18|17 .. 14|13 .. 10|f .. c|b .. 8|7 .. 0|
//   | Opcode |  Arg0  |  Arg1  | Arg2 | Arg3 |  Mod |
//
// with the immediate forms reinterpreting {Arg2, Arg3, Mod} as one 16 bit
// immediate at [15:0].  Section 8 of that document *recommends* repacking
// this to 8 / 5 / 5 / 5 / 8 in a later revision, and says in as many words
// that it "does not change the encoding in sections 4.1 to 4.13"; this
// assembler implements the encoding, not the recommendation.  Section 4.11's
// twelve worked encodings are checked in as tests/gpu_encoding.expect32.
//
// Two things make this ISA need more than asm_parse_fixed:
//
//   * operands are typed.  "v_add_s v13, v13, s6" names two VGPRs and an
//     SGPR, and putting an SGPR where a VGPR belongs is an error the
//     assembler can see, not a different encoding.
//   * the operand count is per instruction, from zero (s_endpgm) to four
//     (v_mad, and every per lane memory access).
//
// Only the scalar half of this exists in gpu16.v today.  The vector, matrix,
// LDS and exec instructions are assembled anyway - the ISA is what is being
// implemented, not the subset of it that currently runs - and are covered by
// encoding tests that compare bytes rather than by simulation.

// What one operand may be.
enum : uint8_t {
    GPU16_K_SREG = 1,   // s0..s15
    GPU16_K_VREG,       // v0..v15
    GPU16_K_VQUAD,      // v0, v4, v8 or v12: the quad of v_ld16_g / v_st16_g
    GPU16_K_ACCBLK,     // A0 or A1, an accumulator block
    GPU16_K_IMM,        // a 16 bit immediate
    GPU16_K_IMMA,       // ... which may be a label, meaning its word address
    GPU16_K_IMMR,       // ... which may be a label, meaning a PC_next offset
    GPU16_K_MOD,        // the whole 8 bit Mod field: a byte offset or a count
    GPU16_K_SHIFT,      // a shift amount in Mod, 0..31
    GPU16_K_LANE,       // a lane index in Mod, 0..15
    GPU16_K_ACCIDX,     // an accumulator index in Mod, 0..31
    GPU16_K_SYSREG,     // a system register number in Mod
};

// An operand is (kind, field), where the field is an index into
// asm_line::arg, which holds {Arg0, Arg1, Arg2, Arg3, Mod}.  An immediate
// lands in arg[2] and the encoder writes it across [15:0] whole.
enum : uint8_t {
    GPU16_S0 = (GPU16_K_SREG   << 4) | 0,
    GPU16_S1 = (GPU16_K_SREG   << 4) | 1,
    GPU16_S2 = (GPU16_K_SREG   << 4) | 2,
    GPU16_V0 = (GPU16_K_VREG   << 4) | 0,
    GPU16_V1 = (GPU16_K_VREG   << 4) | 1,
    GPU16_V2 = (GPU16_K_VREG   << 4) | 2,
    GPU16_V3 = (GPU16_K_VREG   << 4) | 3,
    GPU16_Q0 = (GPU16_K_VQUAD  << 4) | 0,
    GPU16_B0 = (GPU16_K_ACCBLK << 4) | 0,
    GPU16_IM = (GPU16_K_IMM    << 4) | 2,
    GPU16_IA = (GPU16_K_IMMA   << 4) | 2,
    GPU16_IR = (GPU16_K_IMMR   << 4) | 2,
    GPU16_MD = (GPU16_K_MOD    << 4) | 4,
    GPU16_SH = (GPU16_K_SHIFT  << 4) | 4,
    GPU16_LN = (GPU16_K_LANE   << 4) | 4,
    GPU16_AI = (GPU16_K_ACCIDX << 4) | 4,
    GPU16_SY = (GPU16_K_SYSREG << 4) | 4,
};

struct gpu16_sig {
    uint8_t count;
    uint8_t slot[4];
};

// The operand list of every documented instruction, from the per instruction
// field table in section 4.2.
ASM_HD inline gpu16_sig gpu16_signature(uint8_t op) {
    switch (op) {
    // scalar ALU, register-register
    case 0x00: case 0x01: case 0x03: case 0x04: case 0x06: case 0x09:
    case 0x14: case 0x15: case 0x16: case 0x17: case 0x18:
        return gpu16_sig{3, {GPU16_S0, GPU16_S1, GPU16_S2}};
    // scalar ALU, one source
    case 0x02: case 0x08: case 0x0b:
        return gpu16_sig{2, {GPU16_S0, GPU16_S1}};
    // s_imm, whose immediate may be a label's word address
    case 0x0c:
        return gpu16_sig{2, {GPU16_S0, GPU16_IA}};
    // scalar ALU with a 16 bit immediate
    case 0x0d: case 0x1a: case 0x1b: case 0x1c: case 0x1d:
        return gpu16_sig{3, {GPU16_S0, GPU16_S1, GPU16_IM}};
    // scalar shift by Mod
    case 0x0e: case 0x0f: case 0x12:
        return gpu16_sig{3, {GPU16_S0, GPU16_S1, GPU16_SH}};
    // s_addpc, the PC relative address that 'la' expands to
    case 0x13:
        return gpu16_sig{2, {GPU16_S0, GPU16_IR}};
    // s_immh
    case 0x19:
        return gpu16_sig{2, {GPU16_S0, GPU16_IM}};
    // s_rd_sys
    case 0x1e:
        return gpu16_sig{2, {GPU16_S0, GPU16_SY}};
    // conditional branch to a register target
    case 0x20: case 0x21: case 0x23: case 0x24:
        return gpu16_sig{2, {GPU16_S1, GPU16_S2}};
    // s_b
    case 0x22:
        return gpu16_sig{1, {GPU16_S2}};
    // conditional relative branch
    case 0x25: case 0x26:
        return gpu16_sig{2, {GPU16_S1, GPU16_IR}};
    // unconditional and exec relative branches
    case 0x27: case 0x29: case 0x2a:
        return gpu16_sig{1, {GPU16_IR}};
    // s_call
    case 0x28:
        return gpu16_sig{2, {GPU16_S0, GPU16_IR}};
    // s_rd_exec
    case 0x30:
        return gpu16_sig{1, {GPU16_S0}};
    // s_wr_exec
    case 0x31:
        return gpu16_sig{1, {GPU16_S1}};
    // the saveexec family
    case 0x32: case 0x33: case 0x34:
        return gpu16_sig{2, {GPU16_S0, GPU16_S1}};
    // the instructions with no operands at all
    case 0x35: case 0xb0: case 0xb3: case 0xbf:
        return gpu16_sig{0, {0}};
    // vector ALU, register-register
    case 0x40: case 0x41: case 0x43: case 0x44: case 0x45: case 0x47:
    case 0x49: case 0x4a: case 0x4b: case 0x54: case 0x55: case 0x5b:
        return gpu16_sig{3, {GPU16_V0, GPU16_V1, GPU16_V2}};
    // vector ALU, one source
    case 0x42: case 0x46: case 0x4c:
        return gpu16_sig{2, {GPU16_V0, GPU16_V1}};
    // v_mad and v_dot4, the only users of Arg3
    case 0x48: case 0x56:
        return gpu16_sig{4, {GPU16_V0, GPU16_V1, GPU16_V2, GPU16_V3}};
    // v_mov_s
    case 0x4d:
        return gpu16_sig{2, {GPU16_V0, GPU16_S1}};
    // v_imm
    case 0x4e:
        return gpu16_sig{2, {GPU16_V0, GPU16_IM}};
    // vector ALU with a scalar operand
    case 0x4f: case 0x50:
        return gpu16_sig{3, {GPU16_V0, GPU16_V1, GPU16_S2}};
    // vector shift by Mod
    case 0x51: case 0x52: case 0x53:
        return gpu16_sig{3, {GPU16_V0, GPU16_V1, GPU16_SH}};
    // v_lane_id
    case 0x57:
        return gpu16_sig{1, {GPU16_V0}};
    // v_addi
    case 0x58:
        return gpu16_sig{3, {GPU16_V0, GPU16_V1, GPU16_IM}};
    // v_readlane
    case 0x59:
        return gpu16_sig{3, {GPU16_S0, GPU16_V1, GPU16_LN}};
    // v_writelane
    case 0x5a:
        return gpu16_sig{3, {GPU16_V0, GPU16_S1, GPU16_LN}};
    // the compares, which write a mask into an SGPR
    case 0x5c: case 0x5d: case 0x5e: case 0x5f:
        return gpu16_sig{2, {GPU16_S0, GPU16_V1}};
    // mma_i8 and mma_i8_z
    case 0x70: case 0x74:
        return gpu16_sig{3, {GPU16_B0, GPU16_V1, GPU16_V2}};
    // acc_zero
    case 0x71:
        return gpu16_sig{1, {GPU16_B0}};
    // acc_rd
    case 0x72:
        return gpu16_sig{2, {GPU16_V0, GPU16_AI}};
    // acc_wr, whose source is Arg1
    case 0x73:
        return gpu16_sig{2, {GPU16_V1, GPU16_AI}};
    // per lane memory
    case 0x80: case 0x81: case 0x82: case 0x83: case 0x84: case 0xa0:
    case 0xa1: case 0xa2: case 0xa3:
        return gpu16_sig{4, {GPU16_V0, GPU16_V1, GPU16_S2, GPU16_MD}};
    // s_ld_g
    case 0x85:
        return gpu16_sig{3, {GPU16_S0, GPU16_S2, GPU16_MD}};
    // the wide accesses, whose VGPR must start a quad
    case 0x86: case 0x87:
        return gpu16_sig{4, {GPU16_Q0, GPU16_V1, GPU16_S2, GPU16_MD}};
    // the two waitcnts
    case 0xb1: case 0xb2:
        return gpu16_sig{1, {GPU16_MD}};
    default:
        break;
    }
    return gpu16_sig{0, {0}};
}

// True when the instruction spends {Arg2, Arg3, Mod} on one 16 bit
// immediate, which is the one thing the encoder has to know that the operand
// list does not tell it directly.
ASM_HD inline bool gpu16_has_imm(uint8_t op) {
    gpu16_sig sig = gpu16_signature(op);
    for (uint32_t i = 0; i < sig.count; i++) {
        uint8_t kind = static_cast<uint8_t>(sig.slot[i] >> 4);
        if (kind == GPU16_K_IMM || kind == GPU16_K_IMMA || kind == GPU16_K_IMMR) {
            return true;
        }
    }
    return false;
}

// True when a label in that immediate means "this many words from PC_next"
// rather than "this word address".
ASM_HD inline bool gpu16_imm_is_relative(uint8_t op) {
    gpu16_sig sig = gpu16_signature(op);
    for (uint32_t i = 0; i < sig.count; i++) {
        if (static_cast<uint8_t>(sig.slot[i] >> 4) == GPU16_K_IMMR) {
            return true;
        }
    }
    return false;
}

// "s5" -> 5.  Out of range numbers still parse, so that s16 is reported as a
// register that does not exist rather than as a token that is not a register:
// section 8.5 requires the assembler to check that bit 4 is zero, and a
// message saying so is the whole point of checking.
ASM_HD inline bool gpu16_reg(const char* s, uint32_t n, char prefix, int32_t* out) {
    if (n < 2 || n > 3 || s[0] != prefix) {
        return false;
    }
    int32_t value = 0;
    for (uint32_t i = 1; i < n; i++) {
        if (!asm_is_digit(s[i])) {
            return false;
        }
        value = value * 10 + (s[i] - '0');
    }
    *out = value;
    return true;
}

struct asm_gpu16 {
    static constexpr const char* reg_range_text = "this machine has sixteen of each file";
    static constexpr const char* imm_range_text = "does not fit in 16 bits";
    static constexpr const char* branch_range_text = "is too far away to encode in 16 bits";
    static constexpr const char* tool = "asm_gpu16";
    static constexpr uint32_t word_bytes = 4;
    // Which ISA this is, for the backends that dispatch at run time
    // rather than at compile time - asm_hip.hip is compiled once and
    // cannot be a template across the boundary.
    static constexpr int isa_tag = 32;
    static constexpr uint32_t la_words = 1;      // one s_addpc
    static constexpr uint32_t insn_tokens = 0;   // per instruction, see parse()
    static constexpr uint32_t nargs = ASM_MAX_ARGS;
    static constexpr bool has_scratch = false;
    static constexpr bool comma_separated = true;
    static constexpr bool typed_operands = true;
    // Section 4.13: a 16 bit PC, and gpu16.v's program memory is
    // PROGRAM_ADDR_WIDTH = 12 words of it.
    static constexpr uint32_t address_limit = 4095;

    ASM_HD static bool opcode(const char* s, uint32_t n, uint8_t* out) {
        switch (n) {
        case 3:
            if (asm_tok_is(s, n, "s_b"))             { *out = 0x22; return true; }
            break;
        case 4:
            if (asm_tok_is(s, n, "s_or"))            { *out = 0x01; return true; }
            if (asm_tok_is(s, n, "s_bz"))            { *out = 0x21; return true; }
            if (asm_tok_is(s, n, "v_or"))            { *out = 0x41; return true; }
            break;
        case 5:
            if (asm_tok_is(s, n, "s_and"))           { *out = 0x00; return true; }
            if (asm_tok_is(s, n, "s_not"))           { *out = 0x02; return true; }
            if (asm_tok_is(s, n, "s_xor"))           { *out = 0x03; return true; }
            if (asm_tok_is(s, n, "s_add"))           { *out = 0x04; return true; }
            if (asm_tok_is(s, n, "s_sub"))           { *out = 0x06; return true; }
            if (asm_tok_is(s, n, "s_neg"))           { *out = 0x08; return true; }
            if (asm_tok_is(s, n, "s_mul"))           { *out = 0x09; return true; }
            if (asm_tok_is(s, n, "s_mov"))           { *out = 0x0b; return true; }
            if (asm_tok_is(s, n, "s_imm"))           { *out = 0x0c; return true; }
            if (asm_tok_is(s, n, "s_ori"))           { *out = 0x0d; return true; }
            if (asm_tok_is(s, n, "s_shl"))           { *out = 0x14; return true; }
            if (asm_tok_is(s, n, "s_shr"))           { *out = 0x15; return true; }
            if (asm_tok_is(s, n, "s_sar"))           { *out = 0x16; return true; }
            if (asm_tok_is(s, n, "s_min"))           { *out = 0x17; return true; }
            if (asm_tok_is(s, n, "s_max"))           { *out = 0x18; return true; }
            if (asm_tok_is(s, n, "s_bnz"))           { *out = 0x20; return true; }
            if (asm_tok_is(s, n, "s_blz"))           { *out = 0x23; return true; }
            if (asm_tok_is(s, n, "s_bgz"))           { *out = 0x24; return true; }
            if (asm_tok_is(s, n, "s_b_i"))           { *out = 0x27; return true; }
            if (asm_tok_is(s, n, "v_and"))           { *out = 0x40; return true; }
            if (asm_tok_is(s, n, "v_not"))           { *out = 0x42; return true; }
            if (asm_tok_is(s, n, "v_xor"))           { *out = 0x43; return true; }
            if (asm_tok_is(s, n, "v_add"))           { *out = 0x44; return true; }
            if (asm_tok_is(s, n, "v_sub"))           { *out = 0x45; return true; }
            if (asm_tok_is(s, n, "v_neg"))           { *out = 0x46; return true; }
            if (asm_tok_is(s, n, "v_mul"))           { *out = 0x47; return true; }
            if (asm_tok_is(s, n, "v_mad"))           { *out = 0x48; return true; }
            if (asm_tok_is(s, n, "v_shl"))           { *out = 0x49; return true; }
            if (asm_tok_is(s, n, "v_shr"))           { *out = 0x4a; return true; }
            if (asm_tok_is(s, n, "v_sar"))           { *out = 0x4b; return true; }
            if (asm_tok_is(s, n, "v_mov"))           { *out = 0x4c; return true; }
            if (asm_tok_is(s, n, "v_imm"))           { *out = 0x4e; return true; }
            if (asm_tok_is(s, n, "v_min"))           { *out = 0x54; return true; }
            if (asm_tok_is(s, n, "v_max"))           { *out = 0x55; return true; }
            if (asm_tok_is(s, n, "s_nop"))           { *out = 0xbf; return true; }
            break;
        case 6:
            if (asm_tok_is(s, n, "s_shli"))          { *out = 0x0e; return true; }
            if (asm_tok_is(s, n, "s_shri"))          { *out = 0x0f; return true; }
            if (asm_tok_is(s, n, "s_sari"))          { *out = 0x12; return true; }
            if (asm_tok_is(s, n, "s_immh"))          { *out = 0x19; return true; }
            if (asm_tok_is(s, n, "s_addi"))          { *out = 0x1a; return true; }
            if (asm_tok_is(s, n, "s_muli"))          { *out = 0x1b; return true; }
            if (asm_tok_is(s, n, "s_andi"))          { *out = 0x1c; return true; }
            if (asm_tok_is(s, n, "s_xori"))          { *out = 0x1d; return true; }
            if (asm_tok_is(s, n, "s_bz_i"))          { *out = 0x26; return true; }
            if (asm_tok_is(s, n, "s_call"))          { *out = 0x28; return true; }
            if (asm_tok_is(s, n, "v_shli"))          { *out = 0x51; return true; }
            if (asm_tok_is(s, n, "v_shri"))          { *out = 0x52; return true; }
            if (asm_tok_is(s, n, "v_sari"))          { *out = 0x53; return true; }
            if (asm_tok_is(s, n, "v_dot4"))          { *out = 0x56; return true; }
            if (asm_tok_is(s, n, "v_addi"))          { *out = 0x58; return true; }
            if (asm_tok_is(s, n, "mma_i8"))          { *out = 0x70; return true; }
            if (asm_tok_is(s, n, "acc_rd"))          { *out = 0x72; return true; }
            if (asm_tok_is(s, n, "acc_wr"))          { *out = 0x73; return true; }
            if (asm_tok_is(s, n, "v_ld_g"))          { *out = 0x80; return true; }
            if (asm_tok_is(s, n, "v_st_g"))          { *out = 0x83; return true; }
            if (asm_tok_is(s, n, "s_ld_g"))          { *out = 0x85; return true; }
            if (asm_tok_is(s, n, "v_ld_l"))          { *out = 0xa0; return true; }
            if (asm_tok_is(s, n, "v_st_l"))          { *out = 0xa2; return true; }
            break;
        case 7:
            if (asm_tok_is(s, n, "s_addpc"))         { *out = 0x13; return true; }
            if (asm_tok_is(s, n, "s_bnz_i"))         { *out = 0x25; return true; }
            if (asm_tok_is(s, n, "v_mov_s"))         { *out = 0x4d; return true; }
            if (asm_tok_is(s, n, "v_add_s"))         { *out = 0x4f; return true; }
            if (asm_tok_is(s, n, "v_mul_s"))         { *out = 0x50; return true; }
            if (asm_tok_is(s, n, "v_cmp_z"))         { *out = 0x5d; return true; }
            if (asm_tok_is(s, n, "v_ld_gs"))         { *out = 0x81; return true; }
            if (asm_tok_is(s, n, "v_ld4_g"))         { *out = 0x82; return true; }
            if (asm_tok_is(s, n, "v_st4_g"))         { *out = 0x84; return true; }
            if (asm_tok_is(s, n, "v_ld4_l"))         { *out = 0xa1; return true; }
            if (asm_tok_is(s, n, "v_st4_l"))         { *out = 0xa3; return true; }
            break;
        case 8:
            if (asm_tok_is(s, n, "s_rd_sys"))        { *out = 0x1e; return true; }
            if (asm_tok_is(s, n, "v_cmp_nz"))        { *out = 0x5c; return true; }
            if (asm_tok_is(s, n, "v_cmp_lz"))        { *out = 0x5e; return true; }
            if (asm_tok_is(s, n, "v_cmp_gz"))        { *out = 0x5f; return true; }
            if (asm_tok_is(s, n, "acc_zero"))        { *out = 0x71; return true; }
            if (asm_tok_is(s, n, "mma_i8_z"))        { *out = 0x74; return true; }
            if (asm_tok_is(s, n, "v_ld16_g"))        { *out = 0x86; return true; }
            if (asm_tok_is(s, n, "v_st16_g"))        { *out = 0x87; return true; }
            if (asm_tok_is(s, n, "s_endpgm"))        { *out = 0xb3; return true; }
            break;
        case 9:
            if (asm_tok_is(s, n, "s_rd_exec"))       { *out = 0x30; return true; }
            if (asm_tok_is(s, n, "s_wr_exec"))       { *out = 0x31; return true; }
            if (asm_tok_is(s, n, "v_lane_id"))       { *out = 0x57; return true; }
            if (asm_tok_is(s, n, "s_barrier"))       { *out = 0xb0; return true; }
            break;
        case 10:
            if (asm_tok_is(s, n, "s_exec_all"))      { *out = 0x35; return true; }
            if (asm_tok_is(s, n, "v_readlane"))      { *out = 0x59; return true; }
            if (asm_tok_is(s, n, "v_bpermute"))      { *out = 0x5b; return true; }
            break;
        case 11:
            if (asm_tok_is(s, n, "s_cbr_execz"))     { *out = 0x29; return true; }
            if (asm_tok_is(s, n, "v_writelane"))     { *out = 0x5a; return true; }
            if (asm_tok_is(s, n, "s_waitcnt_g"))     { *out = 0xb1; return true; }
            if (asm_tok_is(s, n, "s_waitcnt_l"))     { *out = 0xb2; return true; }
            break;
        case 12:
            if (asm_tok_is(s, n, "s_cbr_execnz"))    { *out = 0x2a; return true; }
            break;
        case 13:
            if (asm_tok_is(s, n, "s_or_saveexec"))   { *out = 0x33; return true; }
            break;
        case 14:
            if (asm_tok_is(s, n, "s_and_saveexec"))  { *out = 0x32; return true; }
            if (asm_tok_is(s, n, "s_xor_saveexec"))  { *out = 0x34; return true; }
            break;
        default:
            break;
        }
        return false;
    }

    // "la s7, label" is one s_addpc: gpu16 has a PC relative address
    // instruction, so the cpu8 and cpu16 trick of folding an address in
    // three bits at a time is not needed here.
    ASM_HD static bool la_dst(const char* s, uint32_t n, int32_t* out) {
        return gpu16_reg(s, n, 's', out) && *out < 16;
    }

    // Parse one typed operand into *value, or return the error that says why
    // it could not be.  A label sets up->label_use and up->name instead.
    ASM_HD static uint8_t operand(const char* s, uint32_t line_off, asm_span tok,
                                  uint8_t slot, asm_line* up, int32_t* value) {
        const char* p = s + tok.off;
        uint32_t n = tok.len;
        uint8_t kind = static_cast<uint8_t>(slot >> 4);
        int32_t v = 0;
        switch (kind) {
        case GPU16_K_SREG:
            if (!gpu16_reg(p, n, 's', &v)) {
                return ASM_ERR_ARG_KIND;
            }
            if (v > 15) {
                return ASM_ERR_REG_RANGE;
            }
            break;
        case GPU16_K_VREG:
            if (!gpu16_reg(p, n, 'v', &v)) {
                return ASM_ERR_ARG_KIND;
            }
            if (v > 15) {
                return ASM_ERR_REG_RANGE;
            }
            break;
        case GPU16_K_VQUAD:
            if (!gpu16_reg(p, n, 'v', &v)) {
                return ASM_ERR_ARG_KIND;
            }
            if (v > 15) {
                return ASM_ERR_REG_RANGE;
            }
            // Section 4.8: the quad rule, "any other value is an encoding
            // error the assembler rejects".
            if ((v & 3) != 0) {
                return ASM_ERR_QUAD_ALIGN;
            }
            break;
        case GPU16_K_ACCBLK:
            if (!gpu16_reg(p, n, 'A', &v) && !gpu16_reg(p, n, 'a', &v) &&
                !asm_parse_number(p, n, &v)) {
                return ASM_ERR_ARG_KIND;
            }
            // 32 accumulators in blocks of 16 is two blocks, A0 and A1.
            if (v < 0 || v > 1) {
                return ASM_ERR_REG_RANGE;
            }
            break;
        case GPU16_K_IMM:
        case GPU16_K_IMMA:
        case GPU16_K_IMMR:
            if (!asm_parse_number(p, n, &v)) {
                if (kind == GPU16_K_IMM) {
                    return ASM_ERR_LABEL_KIND;
                }
                up->label_use = ASM_LABEL_IMM;
                up->name.off = line_off + tok.off;
                up->name.len = tok.len;
                v = 0;
                break;
            }
            // Signed or unsigned, both spellings of the same sixteen bits.
            if (v < -32768 || v > 65535) {
                return ASM_ERR_IMM_RANGE;
            }
            break;
        default:
            if (!asm_parse_number(p, n, &v)) {
                return ASM_ERR_ARG_KIND;
            }
            if (v < 0) {
                return ASM_ERR_MOD_RANGE;
            }
            if (kind == GPU16_K_SHIFT && v > 31) {
                return ASM_ERR_MOD_RANGE;       // a 32 bit register
            }
            if (kind == GPU16_K_LANE && v > 15) {
                return ASM_ERR_MOD_RANGE;       // sixteen lanes, section 1.1
            }
            if (kind == GPU16_K_ACCIDX && v > 31) {
                return ASM_ERR_MOD_RANGE;       // 32 accumulators, section 2.3
            }
            // Section 4.3 lists the system registers as 0-5 and 8-13.  Six,
            // seven and everything above thirteen read as nothing in
            // particular, so they are refused rather than assembled into a
            // load of whatever the hardware happens to leave on the bus.
            if (kind == GPU16_K_SYSREG && (v > 13 || v == 6 || v == 7)) {
                return ASM_ERR_MOD_RANGE;
            }
            if (v > 255) {
                return ASM_ERR_MOD_RANGE;       // Mod is eight bits
            }
            break;
        }
        *value = v;
        return ASM_OK;
    }

    ASM_HD static uint8_t parse(const char* s, uint32_t line_off, const asm_span* t,
                                uint32_t ntokens, asm_line* out) {
        if (!opcode(s + t[0].off, t[0].len, &out->opcode)) {
            return ASM_ERR_OPCODE;
        }
        gpu16_sig sig = gpu16_signature(out->opcode);
        if (ntokens != sig.count + 1u) {
            out->arg[1] = static_cast<int32_t>(sig.count);
            return ASM_ERR_OPERANDS;
        }
        int32_t field[ASM_MAX_ARGS] = {0, 0, 0, 0, 0};
        for (uint32_t i = 0; i < sig.count; i++) {
            int32_t value = 0;
            uint8_t code = operand(s, line_off, t[1 + i], sig.slot[i], out, &value);
            if (code != ASM_OK) {
                out->label_use = ASM_LABEL_NONE;
                out->arg[0] = static_cast<int32_t>(i);
                out->arg[1] = static_cast<int32_t>(sig.count);
                return code;
            }
            field[sig.slot[i] & 0xf] = value;
        }
        for (uint32_t i = 0; i < ASM_MAX_ARGS; i++) {
            out->arg[i] = field[i];
        }
        return ASM_OK;
    }

    // A label resolves to a word address; what goes in the instruction is
    // either that address or its distance from PC_next, and either way it
    // has to fit the sixteen bits the field has.
    ASM_HD static uint8_t check_resolved(const asm_line& l, uint32_t address, int32_t target) {
        if (l.label_use == ASM_LABEL_NONE) {
            return ASM_OK;
        }
        bool relative = l.label_use == ASM_LABEL_LA || gpu16_imm_is_relative(l.opcode);
        int32_t imm = relative ? target - static_cast<int32_t>(address + 1) : target;
        if (imm < -32768 || imm > 65535) {
            return ASM_ERR_BRANCH_RANGE;
        }
        return ASM_OK;
    }

    ASM_HD static uint32_t encode(const asm_statement& s, uint32_t* words) {
        uint8_t op = s.opcode;
        uint32_t a0 = static_cast<uint32_t>(s.arg[0]) & 0xf;
        uint32_t a1 = static_cast<uint32_t>(s.arg[1]) & 0xf;
        uint32_t a2 = static_cast<uint32_t>(s.arg[2]) & 0xf;
        uint32_t a3 = static_cast<uint32_t>(s.arg[3]) & 0xf;
        uint32_t mod = static_cast<uint32_t>(s.arg[4]) & 0xff;
        int32_t imm = s.arg[2];
        if (s.label_use == ASM_LABEL_LA) {
            op = 0x13;                  // s_addpc
            a1 = 0;
            imm = s.target - static_cast<int32_t>(s.address + 1);
        }
        else if (s.label_use == ASM_LABEL_IMM) {
            imm = gpu16_imm_is_relative(op)
                  ? s.target - static_cast<int32_t>(s.address + 1)
                  : s.target;
        }
        uint32_t word = (static_cast<uint32_t>(op) << 24) | (a0 << 20) | (a1 << 16);
        if (gpu16_has_imm(op)) {
            word |= static_cast<uint32_t>(imm) & 0xffff;
        }
        else {
            word |= (a2 << 12) | (a3 << 8) | mod;
        }
        words[0] = word;
        return 1;
    }
};

// ---------------------------------------------------------------- cpu_16_16_16_16

// The ISA of docs/cpu_16_16_16_16.md: a 16 bit word over a 16 bit data path,
// sixteen registers and a 16 bit PC.  Sixteen bits cannot name three of
// sixteen registers and an opcode, so the instruction is two address and the
// word is split six different ways depending on Inst[15:12], the class:
//
//   |f e d c|b a 9 8|7 6 5 4|3 2 1 0|
// R |0 0 op6        |  rs   |  rd   |   classes 0x0-0x3, opcode = Inst[15:8]
// I |class  |    imm8       |  rd   |   classes 0x4-0x7, 0xa, 0xb
// M |class  |  rd   |  rs   | off4  |   classes 0x8, 0x9
// B |1 1 0 0| cond  |    disp8      |   class 0xc
// J |1 1 0 1|      disp12           |   class 0xd  (jmp)
// J |1 1 1 0|      disp12           |   class 0xe  (call)
//
// Like gpu16 and unlike cpu8 and cpu16, the operands are typed and their
// number is per instruction, so this description brings its own parse rather
// than using asm_parse_fixed.
//
// The internal opcode number an asm_line carries is *not* always the encoded
// one, because the encoded one is not unique across formats: an R
// instruction is identified by its 0x00-0x22 opcode byte, everything else by
// 0x80 | class, and a branch by 0xc0 | cond.  encode() puts each back where
// the hardware reads it.

enum : uint8_t {
    CPU1616_K_RD = 1,    // destination register, in the Arg0 slot
    CPU1616_K_RS,        // source register, in the Arg1 slot
    CPU1616_K_IMM8,      // -128..255, both spellings of eight bits
    CPU1616_K_IMM8S,     // -128..127: sign extended, so 128..255 would lie
    CPU1616_K_OFF4,      // 0..15, a displacement in halfwords
    CPU1616_K_SHIFT,     // 0..15, a shift amount, encoded in the rs field
    CPU1616_K_SYS,       // 0..2, a system register, encoded in the rs field
    CPU1616_K_LAB8,      // a label, reached by a signed 8 bit word offset
    CPU1616_K_LAB12,     // a label, reached by a signed 12 bit word offset
};

// An operand is (kind, field), where the field indexes asm_line::arg.
enum : uint8_t {
    CPU1616_RD  = (CPU1616_K_RD    << 4) | 0,
    CPU1616_RS  = (CPU1616_K_RS    << 4) | 1,
    CPU1616_IM  = (CPU1616_K_IMM8  << 4) | 2,
    CPU1616_IS  = (CPU1616_K_IMM8S << 4) | 2,
    CPU1616_OF  = (CPU1616_K_OFF4  << 4) | 2,
    CPU1616_SH  = (CPU1616_K_SHIFT << 4) | 1,
    CPU1616_SY  = (CPU1616_K_SYS   << 4) | 1,
    CPU1616_L8  = (CPU1616_K_LAB8  << 4) | 3,
    CPU1616_L12 = (CPU1616_K_LAB12 << 4) | 3,
};

struct cpu1616_sig {
    uint8_t count;
    uint8_t slot[3];
};

// The operand list of every instruction, from docs/cpu_16_16_16_16.md
// section 9's table of shapes.
ASM_HD inline cpu1616_sig cpu1616_signature(uint8_t op) {
    switch (op) {
    // R format, two registers: rd is read as well as written.
    case 0x00: case 0x01: case 0x02: case 0x03: case 0x04: case 0x05:
    case 0x06: case 0x07: case 0x08: case 0x09: case 0x0a: case 0x0b:
    case 0x0c: case 0x0d: case 0x0e: case 0x0f: case 0x10: case 0x11:
    case 0x12: case 0x18: case 0x19: case 0x1a: case 0x1b: case 0x1c:
        return cpu1616_sig{2, {CPU1616_RD, CPU1616_RS, 0}};
    // shli/shri/sari/roli/rori: the rs field is a shift amount.
    case 0x13: case 0x14: case 0x15: case 0x16: case 0x17:
        return cpu1616_sig{2, {CPU1616_RD, CPU1616_SH, 0}};
    // jmpr/callr name one register and leave rd zero.
    case 0x1d: case 0x1e:
        return cpu1616_sig{1, {CPU1616_RS, 0, 0}};
    // rd_sys: the rs field is a system register number.
    case 0x1f:
        return cpu1616_sig{2, {CPU1616_RD, CPU1616_SY, 0}};
    // halt, nop, ret.
    case 0x20: case 0x21: case 0x22:
        return cpu1616_sig{0, {0, 0, 0}};
    // movi, movih, andi, ori.
    case 0x84: case 0x85: case 0x8a: case 0x8b:
        return cpu1616_sig{2, {CPU1616_RD, CPU1616_IM, 0}};
    // addi, cmpi, whose immediate is sign extended.
    case 0x86: case 0x87:
        return cpu1616_sig{2, {CPU1616_RD, CPU1616_IS, 0}};
    // ld, st.
    case 0x88: case 0x89:
        return cpu1616_sig{3, {CPU1616_RD, CPU1616_RS, CPU1616_OF}};
    // jmp, call.
    case 0x8d: case 0x8e:
        return cpu1616_sig{1, {CPU1616_L12, 0, 0}};
    // and 0xc0..0xce, the fifteen branches.
    default:
        return cpu1616_sig{1, {CPU1616_L8, 0, 0}};
    }
}

// jmp and call reach further than a conditional branch does.
ASM_HD inline bool cpu1616_is_long_jump(uint8_t op) {
    return op == 0x8d || op == 0x8e;
}

struct asm_cpu_16_16_16_16 {
    static constexpr const char* tool = "asm_16_16_16_16";
    static constexpr uint32_t word_bytes = 2;
    // Which ISA this is, for the backends that dispatch at run time rather
    // than at compile time.  The other three tags are named after the
    // instruction word - 8, 16 and 32 - and this ISA's word is also sixteen
    // bits, so it is spelled with the first two numbers of its name instead.
    static constexpr int isa_tag = 1616;
    static constexpr uint32_t la_words = 2;      // movi then movih
    static constexpr uint32_t insn_tokens = 0;   // per instruction, see parse()
    static constexpr uint32_t nargs = ASM_MAX_ARGS;
    static constexpr bool has_scratch = false;
    static constexpr bool comma_separated = true;
    static constexpr bool typed_operands = true;
    // A 16 bit byte addressed PC over instruction words, so 32768 of them.
    static constexpr uint32_t address_limit = 32767;

    static constexpr const char* reg_range_text = "this machine has sixteen registers";
    static constexpr const char* imm_range_text =
        "does not fit this instruction's eight bit immediate";
    static constexpr const char* branch_range_text = "is too far away for this branch";

    ASM_HD static bool opcode(const char* s, uint32_t n, uint8_t* out) {
        switch (n) {
        case 2:
            if (asm_tok_is(s, n, "or"))     { *out = 0x01; return true; }
            if (asm_tok_is(s, n, "ld"))     { *out = 0x88; return true; }
            if (asm_tok_is(s, n, "st"))     { *out = 0x89; return true; }
            if (asm_tok_is(s, n, "br"))     { *out = 0xce; return true; }
            break;
        case 3:
            if (asm_tok_is(s, n, "and"))    { *out = 0x00; return true; }
            if (asm_tok_is(s, n, "not"))    { *out = 0x02; return true; }
            if (asm_tok_is(s, n, "xor"))    { *out = 0x03; return true; }
            if (asm_tok_is(s, n, "add"))    { *out = 0x04; return true; }
            if (asm_tok_is(s, n, "adc"))    { *out = 0x05; return true; }
            if (asm_tok_is(s, n, "sub"))    { *out = 0x06; return true; }
            if (asm_tok_is(s, n, "sbb"))    { *out = 0x07; return true; }
            if (asm_tok_is(s, n, "neg"))    { *out = 0x08; return true; }
            if (asm_tok_is(s, n, "mul"))    { *out = 0x09; return true; }
            if (asm_tok_is(s, n, "div"))    { *out = 0x0a; return true; }
            if (asm_tok_is(s, n, "mov"))    { *out = 0x0b; return true; }
            if (asm_tok_is(s, n, "cmp"))    { *out = 0x0c; return true; }
            if (asm_tok_is(s, n, "tst"))    { *out = 0x0d; return true; }
            if (asm_tok_is(s, n, "shl"))    { *out = 0x0e; return true; }
            if (asm_tok_is(s, n, "shr"))    { *out = 0x0f; return true; }
            if (asm_tok_is(s, n, "sar"))    { *out = 0x10; return true; }
            if (asm_tok_is(s, n, "rol"))    { *out = 0x11; return true; }
            if (asm_tok_is(s, n, "ror"))    { *out = 0x12; return true; }
            if (asm_tok_is(s, n, "ldb"))    { *out = 0x18; return true; }
            if (asm_tok_is(s, n, "stb"))    { *out = 0x19; return true; }
            if (asm_tok_is(s, n, "sxb"))    { *out = 0x1a; return true; }
            if (asm_tok_is(s, n, "min"))    { *out = 0x1b; return true; }
            if (asm_tok_is(s, n, "max"))    { *out = 0x1c; return true; }
            if (asm_tok_is(s, n, "nop"))    { *out = 0x21; return true; }
            if (asm_tok_is(s, n, "ret"))    { *out = 0x22; return true; }
            if (asm_tok_is(s, n, "ori"))    { *out = 0x8b; return true; }
            if (asm_tok_is(s, n, "jmp"))    { *out = 0x8d; return true; }
            if (asm_tok_is(s, n, "beq"))    { *out = 0xc0; return true; }
            if (asm_tok_is(s, n, "bne"))    { *out = 0xc1; return true; }
            if (asm_tok_is(s, n, "blo"))    { *out = 0xc2; return true; }
            if (asm_tok_is(s, n, "bhs"))    { *out = 0xc3; return true; }
            if (asm_tok_is(s, n, "bmi"))    { *out = 0xc4; return true; }
            if (asm_tok_is(s, n, "bpl"))    { *out = 0xc5; return true; }
            if (asm_tok_is(s, n, "bvs"))    { *out = 0xc6; return true; }
            if (asm_tok_is(s, n, "bvc"))    { *out = 0xc7; return true; }
            if (asm_tok_is(s, n, "bhi"))    { *out = 0xc8; return true; }
            if (asm_tok_is(s, n, "bls"))    { *out = 0xc9; return true; }
            if (asm_tok_is(s, n, "bge"))    { *out = 0xca; return true; }
            if (asm_tok_is(s, n, "blt"))    { *out = 0xcb; return true; }
            if (asm_tok_is(s, n, "bgt"))    { *out = 0xcc; return true; }
            if (asm_tok_is(s, n, "ble"))    { *out = 0xcd; return true; }
            break;
        case 4:
            if (asm_tok_is(s, n, "shli"))   { *out = 0x13; return true; }
            if (asm_tok_is(s, n, "shri"))   { *out = 0x14; return true; }
            if (asm_tok_is(s, n, "sari"))   { *out = 0x15; return true; }
            if (asm_tok_is(s, n, "roli"))   { *out = 0x16; return true; }
            if (asm_tok_is(s, n, "rori"))   { *out = 0x17; return true; }
            if (asm_tok_is(s, n, "jmpr"))   { *out = 0x1d; return true; }
            if (asm_tok_is(s, n, "halt"))   { *out = 0x20; return true; }
            if (asm_tok_is(s, n, "movi"))   { *out = 0x84; return true; }
            if (asm_tok_is(s, n, "addi"))   { *out = 0x86; return true; }
            if (asm_tok_is(s, n, "cmpi"))   { *out = 0x87; return true; }
            if (asm_tok_is(s, n, "andi"))   { *out = 0x8a; return true; }
            if (asm_tok_is(s, n, "call"))   { *out = 0x8e; return true; }
            break;
        case 5:
            if (asm_tok_is(s, n, "callr"))  { *out = 0x1e; return true; }
            if (asm_tok_is(s, n, "movih"))  { *out = 0x85; return true; }
            break;
        case 6:
            if (asm_tok_is(s, n, "rd_sys")) { *out = 0x1f; return true; }
            break;
        default:
            break;
        }
        return false;
    }

    // "la rd, label" is movi then movih carrying the label's *byte* address,
    // which reaches the whole 64 KiB - against cpu16's three word expansion
    // and cpu8's ten word one.
    ASM_HD static bool la_dst(const char* s, uint32_t n, int32_t* out) {
        return gpu16_reg(s, n, 'r', out) && *out < 16;
    }

    ASM_HD static bool is_scratch_setter(uint8_t) { return false; }

    ASM_HD static uint8_t operand(const char* s, uint32_t line_off, asm_span tok,
                                  uint8_t slot, asm_line* up, int32_t* value) {
        const char* p = s + tok.off;
        uint32_t n = tok.len;
        uint8_t kind = static_cast<uint8_t>(slot >> 4);
        int32_t v = 0;
        switch (kind) {
        case CPU1616_K_RD:
        case CPU1616_K_RS:
            if (!gpu16_reg(p, n, 'r', &v)) {
                return ASM_ERR_ARG_KIND;
            }
            if (v > 15) {
                return ASM_ERR_REG_RANGE;
            }
            break;
        case CPU1616_K_IMM8:
            if (!asm_parse_number(p, n, &v)) {
                return ASM_ERR_ARG_KIND;
            }
            // Signed or unsigned, both spellings of the same eight bits.
            if (v < -128 || v > 255) {
                return ASM_ERR_IMM_RANGE;
            }
            break;
        case CPU1616_K_IMM8S:
            if (!asm_parse_number(p, n, &v)) {
                return ASM_ERR_ARG_KIND;
            }
            // This one really is signed: the hardware sign extends it, so
            // 200 would quietly mean -56 and is refused instead.
            if (v < -128 || v > 127) {
                return ASM_ERR_IMM_RANGE;
            }
            break;
        case CPU1616_K_OFF4:
        case CPU1616_K_SHIFT:
            if (!asm_parse_number(p, n, &v)) {
                return ASM_ERR_ARG_KIND;
            }
            if (v < 0 || v > 15) {
                return ASM_ERR_MOD_RANGE;
            }
            break;
        case CPU1616_K_SYS:
            if (!asm_parse_number(p, n, &v)) {
                return ASM_ERR_ARG_KIND;
            }
            // Section 7: three system registers, and 3-15 read as nothing in
            // particular, so they are refused rather than assembled into a
            // load of whatever the hardware leaves on the bus.
            if (v < 0 || v > 2) {
                return ASM_ERR_MOD_RANGE;
            }
            break;
        default:
            // A branch target is a label and only a label.  A bare number
            // there would be a word displacement nobody can read back.
            up->label_use = ASM_LABEL_IMM;
            up->name.off = line_off + tok.off;
            up->name.len = tok.len;
            v = 0;
            break;
        }
        *value = v;
        return ASM_OK;
    }

    ASM_HD static uint8_t parse(const char* s, uint32_t line_off, const asm_span* t,
                                uint32_t ntokens, asm_line* out) {
        if (!opcode(s + t[0].off, t[0].len, &out->opcode)) {
            return ASM_ERR_OPCODE;
        }
        cpu1616_sig sig = cpu1616_signature(out->opcode);
        if (ntokens != sig.count + 1u) {
            out->arg[1] = static_cast<int32_t>(sig.count);
            return ASM_ERR_OPERANDS;
        }
        int32_t field[ASM_MAX_ARGS] = {0, 0, 0, 0, 0};
        for (uint32_t i = 0; i < sig.count; i++) {
            int32_t value = 0;
            uint8_t code = operand(s, line_off, t[1 + i], sig.slot[i], out, &value);
            if (code != ASM_OK) {
                out->label_use = ASM_LABEL_NONE;
                out->arg[0] = static_cast<int32_t>(i);
                out->arg[1] = static_cast<int32_t>(sig.count);
                return code;
            }
            field[sig.slot[i] & 0xf] = value;
        }
        for (uint32_t i = 0; i < ASM_MAX_ARGS; i++) {
            out->arg[i] = field[i];
        }
        return ASM_OK;
    }

    // A branch displacement is counted in instruction words from the
    // following instruction, and has to fit the 8 or 12 bits the format
    // leaves for it.  "la" cannot fail: every word address in a program the
    // scan already accepted doubles into sixteen bits.
    ASM_HD static uint8_t check_resolved(const asm_line& l, uint32_t address, int32_t target) {
        if (l.label_use != ASM_LABEL_IMM) {
            return ASM_OK;
        }
        int32_t disp = target - static_cast<int32_t>(address + 1);
        int32_t limit = cpu1616_is_long_jump(l.opcode) ? 2048 : 128;
        if (disp < -limit || disp > limit - 1) {
            return ASM_ERR_BRANCH_RANGE;
        }
        return ASM_OK;
    }

    ASM_HD static uint32_t encode(const asm_statement& s, uint32_t* words) {
        uint32_t rd = static_cast<uint32_t>(s.arg[0]) & 0xf;
        uint32_t rs = static_cast<uint32_t>(s.arg[1]) & 0xf;
        uint32_t imm = static_cast<uint32_t>(s.arg[2]) & 0xff;
        uint32_t off = static_cast<uint32_t>(s.arg[2]) & 0xf;
        uint8_t op = s.opcode;

        if (s.label_use == ASM_LABEL_LA) {
            uint32_t byte_address = static_cast<uint32_t>(s.target) * 2u;
            words[0] = (4u << 12) | ((byte_address & 0xffu) << 4) | rd;
            words[1] = (5u << 12) | (((byte_address >> 8) & 0xffu) << 4) | rd;
            return 2;
        }
        if (op < 0x80) {
            words[0] = (static_cast<uint32_t>(op) << 8) | (rs << 4) | rd;
            return 1;
        }
        int32_t disp = s.target - static_cast<int32_t>(s.address + 1);
        if (op >= 0xc0) {
            words[0] = 0xc000u | ((static_cast<uint32_t>(op) & 0xfu) << 8) |
                       (static_cast<uint32_t>(disp) & 0xffu);
            return 1;
        }
        uint32_t cls = static_cast<uint32_t>(op) & 0xfu;
        if (cls == 8 || cls == 9) {
            words[0] = (cls << 12) | (rd << 8) | (rs << 4) | off;
        }
        else if (cls == 0xd || cls == 0xe) {
            words[0] = (cls << 12) | (static_cast<uint32_t>(disp) & 0xfffu);
        }
        else {
            words[0] = (cls << 12) | (imm << 4) | rd;
        }
        return 1;
    }
};

// ---------------------------------------------------------------- stages

// Lex and parse one line.  Touches nothing outside its own asm_line, which is
// what makes the whole stage parallel.
template <class ISA>
ASM_HD inline void asm_classify_line(const char* buf, asm_span line, asm_line* out) {
    const char* s = buf + line.off;
    uint32_t len = asm_code_length(s, line.len);

    out->nlabels = 0;
    out->ntokens = 0;
    out->name.off = 0;
    out->name.len = 0;
    for (uint32_t i = 0; i < ASM_MAX_ARGS; i++) {
        out->arg[i] = 0;
    }
    out->opcode = 0;
    out->label_use = ASM_LABEL_NONE;
    out->error = ASM_OK;
    out->pad = 0;

    uint32_t pos = 0;
    asm_span tok;
    bool have = asm_next_token(s, len, &pos, &tok, ISA::comma_separated);
    // A label definition is a token ending in ':'.  It may sit on a line of
    // its own or in front of an instruction, and there may be several.
    while (have && asm_is_label_definition(s + tok.off, tok.len)) {
        out->nlabels++;
        have = asm_next_token(s, len, &pos, &tok, ISA::comma_separated);
    }
    if (!have) {
        return;
    }
    // Only the first few tokens can matter: the longest instruction here is
    // gpu16's "<op> <dst> <src0> <src1> <src2>", and any line with more than
    // that is an error that names its token count rather than its tokens.
    asm_span t[ASM_MAX_TOKENS];
    t[0] = tok;
    for (uint32_t i = 1; i < ASM_MAX_TOKENS; i++) {
        t[i] = asm_span{0, 0};
    }
    out->ntokens = 1;
    while (asm_next_token(s, len, &pos, &tok, ISA::comma_separated)) {
        if (out->ntokens < ASM_MAX_TOKENS) {
            t[out->ntokens] = tok;
        }
        out->ntokens++;
    }

    // "la <dst> <label>" is the one pseudo instruction every ISA here has.
    if (asm_tok_is(s + t[0].off, t[0].len, "la")) {
        out->label_use = ASM_LABEL_LA;
        if (out->ntokens != 3) {
            out->error = ASM_ERR_LA_TOKENS;
            return;
        }
        int32_t dst;
        if (!ISA::la_dst(s + t[1].off, t[1].len, &dst)) {
            out->error = ASM_ERR_LA_DST;
            return;
        }
        out->arg[0] = dst;
        out->name.off = line.off + t[2].off;
        out->name.len = t[2].len;
        return;
    }

    out->error = ISA::parse(s, line.off, t, out->ntokens, out);
}

// How many instruction words a classified line occupies.
template <class ISA>
ASM_HD inline uint32_t asm_line_words(const asm_line& l) {
    return l.label_use == ASM_LABEL_LA ? ISA::la_words : 1u;
}

// Place one statement's words in the output buffer.  The offset comes from
// the statement's address alone, so every statement writes a disjoint slice
// and no thread or lane has to agree with any other about where it goes.
ASM_HD inline void asm_write_words(uint8_t* out, uint32_t address,
                                   const uint32_t* words, uint32_t n,
                                   asm_format fmt) {
    const char* digits = "0123456789abcdef";
    uint32_t stride = asm_bytes_per_word(fmt);
    uint8_t* p = out + static_cast<size_t>(address) * stride;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t w = words[i];
        if (fmt.hex) {
            for (uint32_t d = 0; d < 2u * fmt.word_bytes; d++) {
                uint32_t shift = 4u * (2u * fmt.word_bytes - 1u - d);
                p[i * stride + d] = static_cast<uint8_t>(digits[(w >> shift) & 0xf]);
            }
            p[i * stride + 2u * fmt.word_bytes] = static_cast<uint8_t>(fmt.sep);
        }
        else {
            for (uint32_t b = 0; b < fmt.word_bytes; b++) {
                p[i * stride + b] = static_cast<uint8_t>((w >> (8u * b)) & 0xff);
            }
        }
    }
}

// The whole encode stage for one statement.
template <class ISA>
ASM_HD inline void asm_encode_statement(const asm_statement& s, uint8_t* out, asm_format fmt) {
    uint32_t words[ASM_MAX_WORDS];
    uint32_t n = ISA::encode(s, words);
    asm_write_words(out, s.address, words, n, fmt);
}

#endif  // ASM_KERNEL_HPP
