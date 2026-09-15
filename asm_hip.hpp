#ifndef ASM_HIP_HPP
#define ASM_HIP_HPP

// The optional ROCm/HIP backend for the two per line stages.
//
// The implementation lives in asm_hip.hip and is only compiled when CMake
// finds hipcc.  When it is absent these stubs take over, the "hip" backend
// simply refuses to run, and nothing else in the build changes.

#include "asm_kernel.hpp"

#include <cstddef>
#include <string>

#ifdef ASM_HAVE_HIP

bool asm_hip_available();
std::string asm_hip_device_name();
bool asm_hip_classify(int isa, const char* buf, size_t buf_bytes,
                      const asm_span* lines, size_t nlines,
                      asm_line* out, std::string* err);
bool asm_hip_encode(int isa, const asm_statement* statements, size_t n,
                    uint8_t* out, size_t out_bytes, asm_format fmt,
                    std::string* err);

#else

inline bool asm_hip_available() {
    return false;
}

inline std::string asm_hip_device_name() {
    return "none (built without HIP)";
}

inline bool asm_hip_classify(int, const char*, size_t, const asm_span*, size_t,
                             asm_line*, std::string* err) {
    if (err != nullptr) {
        *err = "the hip backend is not available, this build has no ROCm";
    }
    return false;
}

inline bool asm_hip_encode(int, const asm_statement*, size_t, uint8_t*, size_t,
                           asm_format, std::string* err) {
    if (err != nullptr) {
        *err = "the hip backend is not available, this build has no ROCm";
    }
    return false;
}

#endif  // ASM_HAVE_HIP

#endif  // ASM_HIP_HPP
