// The ROCm/HIP backend for the assembler's two parallel stages.
//
// It runs exactly the same asm_classify_line() and asm_encode_statement() the
// CPU backends run - asm_kernel.hpp is written to compile as device code for
// precisely this reason - so the GPU cannot drift away from the CPU's answer
// without the shared code being wrong for both.
//
// Only built when CMake finds hipcc.  See asm_hip.hpp for the stubs that
// stand in when it does not.

#include "asm_hip.hpp"

#include <hip/hip_runtime.h>

#include <cstdio>
#include <string>

namespace {

constexpr int block_size = 256;

bool check(hipError_t e, const char* what, std::string* err) {
    if (e == hipSuccess) {
        return true;
    }
    if (err != nullptr) {
        *err = std::string(what) + ": " + hipGetErrorString(e);
    }
    return false;
}

// A device allocation that frees itself, so the error paths below can simply
// return.
struct device_buffer {
    void* p = nullptr;
    ~device_buffer() {
        if (p != nullptr) {
            (void)hipFree(p);
        }
    }
    bool alloc(size_t bytes, std::string* err) {
        if (bytes == 0) {
            bytes = 1;
        }
        return check(hipMalloc(&p, bytes), "hipMalloc", err);
    }
};

template <class ISA>
__global__ void classify_kernel(const char* buf, const asm_span* lines,
                                size_t n, asm_line* out) {
    size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        asm_classify_line<ISA>(buf, lines[i], &out[i]);
    }
}

template <class ISA>
__global__ void encode_kernel(const asm_statement* statements, size_t n,
                              uint8_t* out, asm_format fmt) {
    size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        asm_encode_statement<ISA>(statements[i], out, fmt);
    }
}

template <class ISA>
bool classify(const char* buf, size_t buf_bytes, const asm_span* lines, size_t nlines,
              asm_line* out, std::string* err) {
    device_buffer d_buf;
    device_buffer d_lines;
    device_buffer d_out;
    if (!d_buf.alloc(buf_bytes, err) ||
        !d_lines.alloc(nlines * sizeof(asm_span), err) ||
        !d_out.alloc(nlines * sizeof(asm_line), err)) {
        return false;
    }
    if (!check(hipMemcpy(d_buf.p, buf, buf_bytes, hipMemcpyHostToDevice), "hipMemcpy source", err) ||
        !check(hipMemcpy(d_lines.p, lines, nlines * sizeof(asm_span), hipMemcpyHostToDevice),
               "hipMemcpy lines", err)) {
        return false;
    }
    size_t blocks = (nlines + block_size - 1) / block_size;
    classify_kernel<ISA><<<dim3(static_cast<unsigned>(blocks)), dim3(block_size)>>>(
        static_cast<const char*>(d_buf.p), static_cast<const asm_span*>(d_lines.p),
        nlines, static_cast<asm_line*>(d_out.p));
    if (!check(hipGetLastError(), "classify kernel", err) ||
        !check(hipDeviceSynchronize(), "classify sync", err)) {
        return false;
    }
    return check(hipMemcpy(out, d_out.p, nlines * sizeof(asm_line), hipMemcpyDeviceToHost),
                 "hipMemcpy lines back", err);
}

template <class ISA>
bool encode(const asm_statement* statements, size_t n, uint8_t* out, size_t out_bytes,
            asm_format fmt, std::string* err) {
    device_buffer d_statements;
    device_buffer d_out;
    if (!d_statements.alloc(n * sizeof(asm_statement), err) ||
        !d_out.alloc(out_bytes, err)) {
        return false;
    }
    if (!check(hipMemcpy(d_statements.p, statements, n * sizeof(asm_statement),
                         hipMemcpyHostToDevice), "hipMemcpy statements", err)) {
        return false;
    }
    size_t blocks = (n + block_size - 1) / block_size;
    encode_kernel<ISA><<<dim3(static_cast<unsigned>(blocks)), dim3(block_size)>>>(
        static_cast<const asm_statement*>(d_statements.p), n,
        static_cast<uint8_t*>(d_out.p), fmt);
    if (!check(hipGetLastError(), "encode kernel", err) ||
        !check(hipDeviceSynchronize(), "encode sync", err)) {
        return false;
    }
    return check(hipMemcpy(out, d_out.p, out_bytes, hipMemcpyDeviceToHost),
                 "hipMemcpy output back", err);
}

}  // namespace

bool asm_hip_available() {
    int count = 0;
    return hipGetDeviceCount(&count) == hipSuccess && count > 0;
}

std::string asm_hip_device_name() {
    int device = 0;
    if (hipGetDevice(&device) != hipSuccess) {
        return "unknown";
    }
    hipDeviceProp_t props;
    if (hipGetDeviceProperties(&props, device) != hipSuccess) {
        return "unknown";
    }
    return std::string(props.name) + " (" + props.gcnArchName + ", " +
           std::to_string(props.multiProcessorCount) + " CUs)";
}

bool asm_hip_classify(int isa, const char* buf, size_t buf_bytes,
                      const asm_span* lines, size_t nlines,
                      asm_line* out, std::string* err) {
    if (nlines == 0) {
        return true;
    }
    if (isa == 8) {
        return classify<asm_cpu8>(buf, buf_bytes, lines, nlines, out, err);
    }
    return classify<asm_cpu16>(buf, buf_bytes, lines, nlines, out, err);
}

bool asm_hip_encode(int isa, const asm_statement* statements, size_t n,
                    uint8_t* out, size_t out_bytes, asm_format fmt,
                    std::string* err) {
    if (n == 0 || out_bytes == 0) {
        return true;
    }
    if (isa == 8) {
        return encode<asm_cpu8>(statements, n, out, out_bytes, fmt, err);
    }
    return encode<asm_cpu16>(statements, n, out, out_bytes, fmt, err);
}
