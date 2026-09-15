#ifndef C16_KERNEL_HPP
#define C16_KERNEL_HPP

// The per item half of the c16 compiler.
//
// Same rule as asm_kernel.hpp, and for the same reason: everything in this
// header compiles both as ordinary C++ and as HIP device code, so no
// std::string, no containers, no exceptions and no pointers into anything but
// one flat buffer.  The serial backend, the std::thread backend and the GPU
// backend all call these functions, which is what makes "every backend emits
// the same bytes" a property of the code rather than a coincidence.
//
// Three stages live here:
//
//   c16_lex_line()      lex one source line into tokens.  A line is a
//                       self contained lexing unit because the only comment
//                       form is "//" to end of line, so this is
//                       embarrassingly parallel.
//   c16_text_length()   how long one lowered item's assembly line is, and
//   c16_text_write()    the line itself.  The text output path.
//   c16_emit_binary()   the same item straight to machine words, by handing
//                       it to the assembler's own asm_encode_statement().
//                       The binary output path.
//
// The parsing and lowering in between is recursive, allocates, and is not
// remotely data parallel per item; it is parallel per function instead and
// lives in c16_compiler.hpp on the host.

#include "asm_kernel.hpp"

#include <cstdint>

// ---------------------------------------------------------------- tokens

enum : uint16_t {
    C16_TOK_IDENT = 0,
    C16_TOK_NUMBER,
    // keywords
    C16_TOK_INT,
    C16_TOK_IF,
    C16_TOK_ELSE,
    C16_TOK_WHILE,
    C16_TOK_RETURN,
    C16_TOK_BREAK,
    C16_TOK_CONTINUE,
    // punctuation
    C16_TOK_LPAREN,
    C16_TOK_RPAREN,
    C16_TOK_LBRACE,
    C16_TOK_RBRACE,
    C16_TOK_SEMI,
    C16_TOK_COMMA,
    C16_TOK_ASSIGN,
    C16_TOK_PLUS,
    C16_TOK_MINUS,
    C16_TOK_STAR,
    C16_TOK_SLASH,
    C16_TOK_AMP,
    C16_TOK_PIPE,
    C16_TOK_CARET,
    C16_TOK_TILDE,
    C16_TOK_BANG,
    C16_TOK_SHL,
    C16_TOK_SHR,
    C16_TOK_EQ,
    C16_TOK_NE,
    C16_TOK_LT,
    C16_TOK_LE,
    C16_TOK_GT,
    C16_TOK_GE,
    C16_TOK_ANDAND,
    C16_TOK_OROR,
    C16_TOK_BAD,       // a character the language has no meaning for
    C16_TOK_END,       // one of these is appended after the last real token
};

struct c16_token {
    uint32_t off;      // offset of the token text in the source buffer
    uint32_t len;
    uint32_t line;     // 1 based, for error messages
    int32_t  value;    // the numeric value, C16_TOK_NUMBER only
    uint16_t kind;
    uint16_t pad;
};

ASM_HD inline bool c16_is_ident_start(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

ASM_HD inline bool c16_is_ident_char(char c) {
    return c16_is_ident_start(c) || asm_is_digit(c);
}

ASM_HD inline bool c16_is_hex_digit(char c) {
    return asm_is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

ASM_HD inline int c16_hex_value(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    return c - 'A' + 10;
}

// The keywords, checked once a word has been lexed.  Same shape as the
// assembler's opcode table: switch on the length first so that most words
// never touch a comparison at all.
ASM_HD inline uint16_t c16_keyword(const char* s, uint32_t n) {
    switch (n) {
    case 2:
        if (asm_tok_is(s, n, "if"))       { return C16_TOK_IF; }
        break;
    case 3:
        if (asm_tok_is(s, n, "int"))      { return C16_TOK_INT; }
        break;
    case 4:
        if (asm_tok_is(s, n, "else"))     { return C16_TOK_ELSE; }
        break;
    case 5:
        if (asm_tok_is(s, n, "while"))    { return C16_TOK_WHILE; }
        if (asm_tok_is(s, n, "break"))    { return C16_TOK_BREAK; }
        break;
    case 6:
        if (asm_tok_is(s, n, "return"))   { return C16_TOK_RETURN; }
        break;
    case 8:
        if (asm_tok_is(s, n, "continue")) { return C16_TOK_CONTINUE; }
        break;
    default:
        break;
    }
    return C16_TOK_IDENT;
}

// Lex one line.  With out == nullptr this only counts, which is how the
// parallel front end sizes the flat token array before filling it.
//
// Returns the number of tokens the line produced.  "//" starts a comment that
// runs to the end of the line, and that is the only comment form there is -
// precisely so that a line can be lexed without knowing anything about the
// lines before it.
ASM_HD inline uint32_t c16_lex_line(const char* buf, asm_span line, uint32_t line_number,
                                    c16_token* out) {
    const char* s = buf + line.off;
    uint32_t len = line.len;
    uint32_t count = 0;
    uint32_t i = 0;

    while (i < len) {
        char c = s[i];
        if (asm_is_space(c)) {
            i++;
            continue;
        }
        if (c == '/' && i + 1 < len && s[i + 1] == '/') {
            break;
        }

        uint32_t begin = i;
        uint16_t kind = C16_TOK_BAD;
        int32_t value = 0;

        if (c16_is_ident_start(c)) {
            while (i < len && c16_is_ident_char(s[i])) {
                i++;
            }
            kind = c16_keyword(s + begin, i - begin);
        }
        else if (asm_is_digit(c)) {
            kind = C16_TOK_NUMBER;
            if (c == '0' && i + 2 < len && (s[i + 1] == 'x' || s[i + 1] == 'X') &&
                c16_is_hex_digit(s[i + 2])) {
                i += 2;
                int64_t v = 0;
                while (i < len && c16_is_hex_digit(s[i])) {
                    v = v * 16 + c16_hex_value(s[i]);
                    if (v > 0x10000) {
                        v = 0x10000;   // saturate; the parser rejects it
                    }
                    i++;
                }
                value = static_cast<int32_t>(v);
            }
            else {
                int64_t v = 0;
                while (i < len && asm_is_digit(s[i])) {
                    v = v * 10 + (s[i] - '0');
                    if (v > 0x10000) {
                        v = 0x10000;
                    }
                    i++;
                }
                value = static_cast<int32_t>(v);
            }
            // "12abc" is not a number followed by a name, it is a bad token.
            if (i < len && c16_is_ident_char(s[i])) {
                while (i < len && c16_is_ident_char(s[i])) {
                    i++;
                }
                kind = C16_TOK_BAD;
            }
        }
        else {
            char d = i + 1 < len ? s[i + 1] : '\0';
            i++;
            switch (c) {
            case '(': kind = C16_TOK_LPAREN; break;
            case ')': kind = C16_TOK_RPAREN; break;
            case '{': kind = C16_TOK_LBRACE; break;
            case '}': kind = C16_TOK_RBRACE; break;
            case ';': kind = C16_TOK_SEMI;   break;
            case ',': kind = C16_TOK_COMMA;  break;
            case '+': kind = C16_TOK_PLUS;   break;
            case '-': kind = C16_TOK_MINUS;  break;
            case '*': kind = C16_TOK_STAR;   break;
            case '/': kind = C16_TOK_SLASH;  break;
            case '^': kind = C16_TOK_CARET;  break;
            case '~': kind = C16_TOK_TILDE;  break;
            case '=':
                if (d == '=') { kind = C16_TOK_EQ; i++; } else { kind = C16_TOK_ASSIGN; }
                break;
            case '!':
                if (d == '=') { kind = C16_TOK_NE; i++; } else { kind = C16_TOK_BANG; }
                break;
            case '<':
                if (d == '=')      { kind = C16_TOK_LE;  i++; }
                else if (d == '<') { kind = C16_TOK_SHL; i++; }
                else               { kind = C16_TOK_LT; }
                break;
            case '>':
                if (d == '=')      { kind = C16_TOK_GE;  i++; }
                else if (d == '>') { kind = C16_TOK_SHR; i++; }
                else               { kind = C16_TOK_GT; }
                break;
            case '&':
                if (d == '&') { kind = C16_TOK_ANDAND; i++; } else { kind = C16_TOK_AMP; }
                break;
            case '|':
                if (d == '|') { kind = C16_TOK_OROR; i++; } else { kind = C16_TOK_PIPE; }
                break;
            default:
                kind = C16_TOK_BAD;
                break;
            }
        }

        if (out != nullptr) {
            c16_token t;
            t.off = line.off + begin;
            t.len = i - begin;
            t.line = line_number;
            t.value = value;
            t.kind = kind;
            t.pad = 0;
            out[count] = t;
        }
        count++;
    }
    return count;
}

// ---------------------------------------------------------------- items

// What lowering produces.  One item is either a label definition, a plain
// cpu16 instruction, or the assembler's "la" pseudo instruction.  Nothing
// else: the compiler never computes a branch address itself, it names a label
// and lets "la" carry it, exactly the way a hand written program does.
enum : uint8_t {
    C16_ITEM_LABEL = 0,   // "L<label>:"      - zero words
    C16_ITEM_INSN  = 1,   // "<op> a0 a1 a2"  - one word
    C16_ITEM_LA    = 2,   // "la r<a0> L<n>"  - three words
};

struct c16_item {
    uint32_t address;   // instruction word address, filled in by layout
    uint32_t label;     // label id: defined (LABEL) or referenced (LA)
    int32_t  target;    // the label's address, filled in by resolve (LA only)
    uint8_t  kind;
    uint8_t  opcode;
    int8_t   arg[3];
    uint8_t  pad[3];
};

ASM_HD inline uint32_t c16_item_words(const c16_item& it) {
    switch (it.kind) {
    case C16_ITEM_LA:   return asm_cpu16::la_words;
    case C16_ITEM_INSN: return 1;
    default:            return 0;
    }
}

// ------------------------------------------------------- the text path

// The mnemonic for an opcode.  Only the opcodes the compiler actually emits
// need to be here, but the whole cpu16 table is cheap and keeps the two
// directions - assembling and disassembling - obviously in step.
ASM_HD inline uint32_t c16_mnemonic(uint8_t opcode, char* out) {
    const char* m = "?";
    switch (opcode) {
    case  0: m = "and";    break;
    case  1: m = "or";     break;
    case  2: m = "not";    break;
    case  3: m = "xor";    break;
    case  4: m = "add";    break;
    case  5: m = "adc";    break;
    case  6: m = "sub";    break;
    case  7: m = "sbb";    break;
    case  8: m = "neg";    break;
    case  9: m = "mul";    break;
    case 10: m = "div";    break;
    case 11: m = "mov";    break;
    case 12: m = "imm";    break;
    case 13: m = "imm_s";  break;
    case 14: m = "shl";    break;
    case 15: m = "shr";    break;
    case 16: m = "srl";    break;
    case 17: m = "srr";    break;
    case 18: m = "sar";    break;
    case 19: m = "add_ip"; break;
    case 32: m = "bnz";    break;
    case 33: m = "bz";     break;
    case 34: m = "b";      break;
    case 35: m = "blz";    break;
    case 36: m = "bgz";    break;
    case 64: m = "ld";     break;
    case 65: m = "st";     break;
    case 66: m = "cl";     break;
    case 67: m = "swap";   break;
    case 68: m = "ld_p";   break;
    case 69: m = "st_p";   break;
    default: break;
    }
    uint32_t n = 0;
    while (m[n] != '\0') {
        if (out != nullptr) {
            out[n] = m[n];
        }
        n++;
    }
    return n;
}

ASM_HD inline uint32_t c16_uint_len(uint32_t v) {
    uint32_t n = 1;
    while (v >= 10) {
        v /= 10;
        n++;
    }
    return n;
}

ASM_HD inline uint32_t c16_write_uint(char* out, uint32_t v) {
    uint32_t n = c16_uint_len(v);
    for (uint32_t i = 0; i < n; i++) {
        out[n - 1 - i] = static_cast<char>('0' + v % 10);
        v /= 10;
    }
    return n;
}

// How many characters one item's assembly line occupies.  The text stage
// needs this before it can write anything, because the lines are of different
// lengths and every item has to know its own offset without asking its
// neighbours.  A parallel prefix sum over these is what turns that into an
// offset.
ASM_HD inline uint32_t c16_text_length(const c16_item& it) {
    switch (it.kind) {
    case C16_ITEM_LABEL:
        // "L<n>:\n"
        return 1 + c16_uint_len(it.label) + 2;
    case C16_ITEM_LA:
        // "la r<d> L<n>\n"
        return 8 + c16_uint_len(it.label);
    default:
        // "<mnemonic> r<a> r<b> r<c>\n"
        return c16_mnemonic(it.opcode, nullptr) + 10;
    }
}

ASM_HD inline uint32_t c16_text_write(const c16_item& it, char* out) {
    uint32_t n = 0;
    if (it.kind == C16_ITEM_LABEL) {
        out[n++] = 'L';
        n += c16_write_uint(out + n, it.label);
        out[n++] = ':';
        out[n++] = '\n';
        return n;
    }
    if (it.kind == C16_ITEM_LA) {
        out[n++] = 'l';
        out[n++] = 'a';
        out[n++] = ' ';
        out[n++] = 'r';
        out[n++] = static_cast<char>('0' + it.arg[0]);
        out[n++] = ' ';
        out[n++] = 'L';
        n += c16_write_uint(out + n, it.label);
        out[n++] = '\n';
        return n;
    }
    n += c16_mnemonic(it.opcode, out);
    for (uint32_t a = 0; a < 3; a++) {
        out[n++] = ' ';
        out[n++] = 'r';
        out[n++] = static_cast<char>('0' + it.arg[a]);
    }
    out[n++] = '\n';
    return n;
}

// ----------------------------------------------------- the binary path

// The same item, straight to machine words.  No text is formatted and nothing
// is lexed again: the item is handed to the assembler's own encoder, which is
// the whole point of the exercise.  A label definition occupies no words and
// writes nothing.
ASM_HD inline void c16_emit_binary(const c16_item& it, uint8_t* out, asm_format fmt) {
    if (it.kind == C16_ITEM_LABEL) {
        return;
    }
    asm_statement s;
    s.line_index = 0;
    s.address = it.address;
    s.target = it.target;
    s.arg[0] = it.arg[0];
    s.arg[1] = it.arg[1];
    s.arg[2] = it.arg[2];
    s.opcode = it.opcode;
    s.is_la = it.kind == C16_ITEM_LA ? 1 : 0;
    s.pad[0] = s.pad[1] = s.pad[2] = 0;
    asm_encode_statement<asm_cpu16>(s, out, fmt);
}

#endif  // C16_KERNEL_HPP
