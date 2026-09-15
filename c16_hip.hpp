#ifndef C16_HIP_HPP
#define C16_HIP_HPP

// The optional ROCm/HIP backend for the compiler's per item stages.
//
// Exactly the same arrangement as asm_hip.hpp: the implementation lives in
// c16_hip.hip and is only compiled when CMake finds hipcc, and without it
// these stubs make the "hip" backend refuse to run while nothing else in the
// build changes.
//
// Three stages are offered, which between them are every stage of the
// compiler whose work is independent per item:
//
//   lex     count the tokens on each line, then fill them in
//   text    the length of each assembly line, then write the lines
//   binary  encode each item straight to machine words
//
// The prefix sums in between the halves of lex and text stay on the host.
// They are one pass over an array of 32 bit counters, they are ordered, and
// they are the same code for every backend, which is part of why the backends
// cannot disagree.

#include "asm_kernel.hpp"
#include "c16_kernel.hpp"

#include <cstddef>
#include <string>

#ifdef C16_HAVE_HIP

bool c16_hip_available();
std::string c16_hip_device_name();
bool c16_hip_lex_count(const char* buf, size_t bytes, const asm_span* lines, size_t nlines,
                       uint32_t* counts, std::string* err);
bool c16_hip_lex_fill(const char* buf, size_t bytes, const asm_span* lines, size_t nlines,
                      const uint32_t* offsets, c16_token* out, size_t ntokens,
                      std::string* err);
bool c16_hip_text_lengths(const c16_item* items, size_t n, uint32_t* lengths,
                          std::string* err);
bool c16_hip_text_write(const c16_item* items, size_t n, const uint32_t* offsets,
                        uint8_t* out, size_t out_bytes, std::string* err);
bool c16_hip_binary(const c16_item* items, size_t n, uint8_t* out, size_t out_bytes,
                    asm_format fmt, std::string* err);

#else

inline bool c16_hip_available() {
    return false;
}

inline std::string c16_hip_device_name() {
    return "none (built without HIP)";
}

inline bool c16_hip_unavailable(std::string* err) {
    if (err != nullptr) {
        *err = "the hip backend is not available, this build has no ROCm";
    }
    return false;
}

inline bool c16_hip_lex_count(const char*, size_t, const asm_span*, size_t,
                              uint32_t*, std::string* err) {
    return c16_hip_unavailable(err);
}

inline bool c16_hip_lex_fill(const char*, size_t, const asm_span*, size_t,
                             const uint32_t*, c16_token*, size_t, std::string* err) {
    return c16_hip_unavailable(err);
}

inline bool c16_hip_text_lengths(const c16_item*, size_t, uint32_t*, std::string* err) {
    return c16_hip_unavailable(err);
}

inline bool c16_hip_text_write(const c16_item*, size_t, const uint32_t*, uint8_t*,
                               size_t, std::string* err) {
    return c16_hip_unavailable(err);
}

inline bool c16_hip_binary(const c16_item*, size_t, uint8_t*, size_t, asm_format,
                           std::string* err) {
    return c16_hip_unavailable(err);
}

#endif  // C16_HAVE_HIP

#endif  // C16_HIP_HPP
