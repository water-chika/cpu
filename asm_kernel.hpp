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
    ASM_MAX_WORDS = 10,  // the longest "la" expansion, cpu8's
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
// parse or did not fit in 3 bits is reported from its source text instead.
struct asm_line {
    uint32_t nlabels;     // how many "label:" definitions the line opens with
    uint32_t ntokens;     // how many tokens follow them
    asm_span name;        // the label operand of "la", when is_la
    int8_t   arg[3];
    uint8_t  opcode;      // the encoded opcode value, not an index
    uint8_t  is_la;
    uint8_t  error;
    uint8_t  pad;
};

// One line that actually assembles to something, after the scan has given it
// an address and resolved its label.
struct asm_statement {
    uint32_t line_index;
    uint32_t address;     // in instruction words
    int32_t  target;      // resolved label address, "la" only
    int8_t   arg[3];
    uint8_t  opcode;
    uint8_t  is_la;
    uint8_t  pad[3];
};

// How the words are laid out in the output buffer.
struct asm_format {
    uint8_t hex;                       // text instead of raw little endian
    uint8_t word_bytes;                // 1 for cpu8, 2 for cpu16
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

// Step to the next whitespace separated token.  Returns false at end of line.
ASM_HD inline bool asm_next_token(const char* s, uint32_t len, uint32_t* pos, asm_span* out) {
    uint32_t i = *pos;
    while (i < len && asm_is_space(s[i])) {
        i++;
    }
    if (i >= len) {
        *pos = i;
        return false;
    }
    uint32_t begin = i;
    while (i < len && !asm_is_space(s[i])) {
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

// ---------------------------------------------------------------- cpu8

// The 8 bit ISA.  Instruction word: opcode in the top 5 bits, one 3 bit
// operand below it.
struct asm_cpu8 {
    static constexpr const char* tool = "asm";
    static constexpr uint32_t word_bytes = 1;
    static constexpr uint32_t la_words = 10;
    static constexpr uint32_t insn_tokens = 2;   // "<op> <arg>"
    static constexpr uint32_t nargs = 1;
    static constexpr bool has_scratch = true;    // "la" needs set_src1_dst1

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

    ASM_HD static uint32_t encode(const asm_statement& s, uint16_t* words) {
        if (!s.is_la) {
            words[0] = static_cast<uint16_t>((s.opcode << 3) | s.arg[0]);
            return 1;
        }
        // The 8 bit CPU moves 3 bits of immediate at a time and has no
        // or-with-immediate, so a label address is folded into the
        // destination three bits at a time through the src1/dst1 scratch.
        int32_t dst = s.arg[0];
        int32_t t = s.target;
        words[0] = static_cast<uint16_t>((11 << 3) | ((t >> 6) & 3));  // imm
        words[1] = static_cast<uint16_t>((12 << 3) | 3);               // shl 3
        words[2] = static_cast<uint16_t>(( 9 << 3) | dst);             // mov
        words[3] = static_cast<uint16_t>((11 << 3) | ((t >> 3) & 7));  // imm
        words[4] = static_cast<uint16_t>(( 1 << 3) | dst);             // or
        words[5] = static_cast<uint16_t>((10 << 3) | dst);             // mov0
        words[6] = static_cast<uint16_t>((12 << 3) | 3);               // shl 3
        words[7] = static_cast<uint16_t>(( 9 << 3) | dst);             // mov
        words[8] = static_cast<uint16_t>((11 << 3) | (t & 7));         // imm
        words[9] = static_cast<uint16_t>(( 1 << 3) | dst);             // or
        return 10;
    }
};

// ---------------------------------------------------------------- cpu16

// The 16 bit ISA.  Instruction word: opcode in the top 7 bits, three 3 bit
// operands below it.
struct asm_cpu16 {
    static constexpr const char* tool = "asm16";
    static constexpr uint32_t word_bytes = 2;
    static constexpr uint32_t la_words = 3;
    static constexpr uint32_t insn_tokens = 4;   // "<op> <arg0> <arg1> <arg2>"
    static constexpr uint32_t nargs = 3;
    static constexpr bool has_scratch = false;

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

    ASM_HD static uint32_t encode(const asm_statement& s, uint16_t* words) {
        if (!s.is_la) {
            words[0] = static_cast<uint16_t>((s.opcode << 9) | (s.arg[0] << 6) |
                                             (s.arg[1] << 3) | s.arg[2]);
            return 1;
        }
        int32_t dst = s.arg[0];
        int32_t t = s.target;
        words[0] = static_cast<uint16_t>((12 << 9) | (((t >> 6) & 3) << 6) | (6 << 3) | dst);
        words[1] = static_cast<uint16_t>((13 << 9) | (((t >> 3) & 7) << 6) | (3 << 3) | dst);
        words[2] = static_cast<uint16_t>((13 << 9) | (( t       & 7) << 6) | (0 << 3) | dst);
        return 3;
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
    out->arg[0] = out->arg[1] = out->arg[2] = 0;
    out->opcode = 0;
    out->is_la = 0;
    out->error = ASM_OK;
    out->pad = 0;

    uint32_t pos = 0;
    asm_span tok;
    bool have = asm_next_token(s, len, &pos, &tok);
    // A label definition is a token ending in ':'.  It may sit on a line of
    // its own or in front of an instruction, and there may be several.
    while (have && asm_is_label_definition(s + tok.off, tok.len)) {
        out->nlabels++;
        have = asm_next_token(s, len, &pos, &tok);
    }
    if (!have) {
        return;
    }
    // Only the first four tokens can matter: cpu16's longest instruction is
    // "<op> <arg0> <arg1> <arg2>", and any line with more than that is an
    // error that names its token count rather than its tokens.
    asm_span t[4];
    t[0] = tok;
    t[1] = t[2] = t[3] = asm_span{0, 0};
    out->ntokens = 1;
    while (asm_next_token(s, len, &pos, &tok)) {
        if (out->ntokens < 4) {
            t[out->ntokens] = tok;
        }
        out->ntokens++;
    }

    out->is_la = asm_tok_is(s + t[0].off, t[0].len, "la") ? 1 : 0;

    if (out->is_la) {
        if (out->ntokens != 3) {
            out->error = ASM_ERR_LA_TOKENS;
            return;
        }
        int32_t dst;
        if (!asm_register(s + t[1].off, t[1].len, &dst)) {
            out->error = ASM_ERR_LA_DST;
            return;
        }
        out->arg[0] = static_cast<int8_t>(dst);
        out->name.off = line.off + t[2].off;
        out->name.len = t[2].len;
        return;
    }

    if (out->ntokens != ISA::insn_tokens) {
        out->error = ASM_ERR_TOKENS;
        return;
    }
    if (!ISA::opcode(s + t[0].off, t[0].len, &out->opcode)) {
        out->error = ASM_ERR_OPCODE;
        return;
    }
    int32_t parsed[3] = {0, 0, 0};
    for (uint32_t i = 0; i < ISA::nargs; i++) {
        if (!ISA::arg(s + t[1 + i].off, t[1 + i].len, &parsed[i])) {
            out->error = ASM_ERR_ARG;
            return;
        }
    }
    for (uint32_t i = 0; i < ISA::nargs; i++) {
        if (parsed[i] < 0 || parsed[i] > 7) {
            out->error = static_cast<uint8_t>(ASM_ERR_ARG_RANGE0 + i);
            return;
        }
    }
    for (uint32_t i = 0; i < ISA::nargs; i++) {
        out->arg[i] = static_cast<int8_t>(parsed[i]);
    }
}

// How many instruction words a classified line occupies.
template <class ISA>
ASM_HD inline uint32_t asm_line_words(const asm_line& l) {
    return l.is_la ? ISA::la_words : 1u;
}

// Place one statement's words in the output buffer.  The offset comes from
// the statement's address alone, so every statement writes a disjoint slice
// and no thread or lane has to agree with any other about where it goes.
ASM_HD inline void asm_write_words(uint8_t* out, uint32_t address,
                                   const uint16_t* words, uint32_t n,
                                   asm_format fmt) {
    const char* digits = "0123456789abcdef";
    uint32_t stride = asm_bytes_per_word(fmt);
    uint8_t* p = out + static_cast<size_t>(address) * stride;
    for (uint32_t i = 0; i < n; i++) {
        uint16_t w = words[i];
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
    uint16_t words[ASM_MAX_WORDS];
    uint32_t n = ISA::encode(s, words);
    asm_write_words(out, s.address, words, n, fmt);
}

#endif  // ASM_KERNEL_HPP
