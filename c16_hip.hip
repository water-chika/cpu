// The ROCm/HIP backend for the compiler's per item stages.
//
// It runs exactly the functions the CPU backends run - c16_lex_line(),
// c16_text_length(), c16_text_write() and c16_emit_binary(), all of which
// c16_kernel.hpp writes as device compilable code for precisely this reason -
// so the GPU cannot drift away from the CPU's answer without the shared code
// being wrong for both.
//
// Only built when CMake finds hipcc.  See c16_hip.hpp for the stubs that
// stand in when it does not.

#include "c16_hip.hpp"

#include <hip/hip_runtime.h>

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

bool launched(const char* what, std::string* err) {
    return check(hipGetLastError(), what, err) &&
           check(hipDeviceSynchronize(), what, err);
}

unsigned blocks_for(size_t n) {
    return static_cast<unsigned>((n + block_size - 1) / block_size);
}

__global__ void lex_count_kernel(const char* buf, const asm_span* lines, size_t n,
                                 uint32_t* counts) {
    size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        counts[i] = c16_lex_line(buf, lines[i], static_cast<uint32_t>(i) + 1, nullptr);
    }
}

__global__ void lex_fill_kernel(const char* buf, const asm_span* lines, size_t n,
                                const uint32_t* offsets, c16_token* out) {
    size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        c16_lex_line(buf, lines[i], static_cast<uint32_t>(i) + 1, out + offsets[i]);
    }
}

__global__ void text_length_kernel(const c16_item* items, size_t n, uint32_t* lengths) {
    size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        lengths[i] = c16_text_length(items[i]);
    }
}

__global__ void text_write_kernel(const c16_item* items, size_t n,
                                  const uint32_t* offsets, char* out) {
    size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        c16_text_write(items[i], out + offsets[i]);
    }
}

__global__ void binary_kernel(const c16_item* items, size_t n, uint8_t* out,
                              asm_format fmt) {
    size_t i = static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i < n) {
        c16_emit_binary(items[i], out, fmt);
    }
}

}  // namespace

bool c16_hip_available() {
    int count = 0;
    return hipGetDeviceCount(&count) == hipSuccess && count > 0;
}

std::string c16_hip_device_name() {
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

bool c16_hip_lex_count(const char* buf, size_t bytes, const asm_span* lines, size_t nlines,
                       uint32_t* counts, std::string* err) {
    if (nlines == 0) {
        return true;
    }
    device_buffer d_buf;
    device_buffer d_lines;
    device_buffer d_counts;
    if (!d_buf.alloc(bytes, err) || !d_lines.alloc(nlines * sizeof(asm_span), err) ||
        !d_counts.alloc(nlines * sizeof(uint32_t), err)) {
        return false;
    }
    if (!check(hipMemcpy(d_buf.p, buf, bytes, hipMemcpyHostToDevice), "hipMemcpy source", err) ||
        !check(hipMemcpy(d_lines.p, lines, nlines * sizeof(asm_span), hipMemcpyHostToDevice),
               "hipMemcpy lines", err)) {
        return false;
    }
    lex_count_kernel<<<dim3(blocks_for(nlines)), dim3(block_size)>>>(
        static_cast<const char*>(d_buf.p), static_cast<const asm_span*>(d_lines.p),
        nlines, static_cast<uint32_t*>(d_counts.p));
    if (!launched("lex count kernel", err)) {
        return false;
    }
    return check(hipMemcpy(counts, d_counts.p, nlines * sizeof(uint32_t),
                           hipMemcpyDeviceToHost), "hipMemcpy counts back", err);
}

bool c16_hip_lex_fill(const char* buf, size_t bytes, const asm_span* lines, size_t nlines,
                      const uint32_t* offsets, c16_token* out, size_t ntokens,
                      std::string* err) {
    if (nlines == 0 || ntokens == 0) {
        return true;
    }
    device_buffer d_buf;
    device_buffer d_lines;
    device_buffer d_offsets;
    device_buffer d_out;
    if (!d_buf.alloc(bytes, err) || !d_lines.alloc(nlines * sizeof(asm_span), err) ||
        !d_offsets.alloc(nlines * sizeof(uint32_t), err) ||
        !d_out.alloc(ntokens * sizeof(c16_token), err)) {
        return false;
    }
    if (!check(hipMemcpy(d_buf.p, buf, bytes, hipMemcpyHostToDevice), "hipMemcpy source", err) ||
        !check(hipMemcpy(d_lines.p, lines, nlines * sizeof(asm_span), hipMemcpyHostToDevice),
               "hipMemcpy lines", err) ||
        !check(hipMemcpy(d_offsets.p, offsets, nlines * sizeof(uint32_t),
                         hipMemcpyHostToDevice), "hipMemcpy offsets", err)) {
        return false;
    }
    lex_fill_kernel<<<dim3(blocks_for(nlines)), dim3(block_size)>>>(
        static_cast<const char*>(d_buf.p), static_cast<const asm_span*>(d_lines.p),
        nlines, static_cast<const uint32_t*>(d_offsets.p),
        static_cast<c16_token*>(d_out.p));
    if (!launched("lex fill kernel", err)) {
        return false;
    }
    return check(hipMemcpy(out, d_out.p, ntokens * sizeof(c16_token), hipMemcpyDeviceToHost),
                 "hipMemcpy tokens back", err);
}

bool c16_hip_text_lengths(const c16_item* items, size_t n, uint32_t* lengths,
                          std::string* err) {
    if (n == 0) {
        return true;
    }
    device_buffer d_items;
    device_buffer d_lengths;
    if (!d_items.alloc(n * sizeof(c16_item), err) ||
        !d_lengths.alloc(n * sizeof(uint32_t), err)) {
        return false;
    }
    if (!check(hipMemcpy(d_items.p, items, n * sizeof(c16_item), hipMemcpyHostToDevice),
               "hipMemcpy items", err)) {
        return false;
    }
    text_length_kernel<<<dim3(blocks_for(n)), dim3(block_size)>>>(
        static_cast<const c16_item*>(d_items.p), n, static_cast<uint32_t*>(d_lengths.p));
    if (!launched("text length kernel", err)) {
        return false;
    }
    return check(hipMemcpy(lengths, d_lengths.p, n * sizeof(uint32_t), hipMemcpyDeviceToHost),
                 "hipMemcpy lengths back", err);
}

bool c16_hip_text_write(const c16_item* items, size_t n, const uint32_t* offsets,
                        uint8_t* out, size_t out_bytes, std::string* err) {
    if (n == 0 || out_bytes == 0) {
        return true;
    }
    device_buffer d_items;
    device_buffer d_offsets;
    device_buffer d_out;
    if (!d_items.alloc(n * sizeof(c16_item), err) ||
        !d_offsets.alloc(n * sizeof(uint32_t), err) || !d_out.alloc(out_bytes, err)) {
        return false;
    }
    if (!check(hipMemcpy(d_items.p, items, n * sizeof(c16_item), hipMemcpyHostToDevice),
               "hipMemcpy items", err) ||
        !check(hipMemcpy(d_offsets.p, offsets, n * sizeof(uint32_t), hipMemcpyHostToDevice),
               "hipMemcpy offsets", err)) {
        return false;
    }
    text_write_kernel<<<dim3(blocks_for(n)), dim3(block_size)>>>(
        static_cast<const c16_item*>(d_items.p), n,
        static_cast<const uint32_t*>(d_offsets.p), static_cast<char*>(d_out.p));
    if (!launched("text write kernel", err)) {
        return false;
    }
    return check(hipMemcpy(out, d_out.p, out_bytes, hipMemcpyDeviceToHost),
                 "hipMemcpy text back", err);
}

bool c16_hip_binary(const c16_item* items, size_t n, uint8_t* out, size_t out_bytes,
                    asm_format fmt, std::string* err) {
    if (n == 0 || out_bytes == 0) {
        return true;
    }
    device_buffer d_items;
    device_buffer d_out;
    if (!d_items.alloc(n * sizeof(c16_item), err) || !d_out.alloc(out_bytes, err)) {
        return false;
    }
    if (!check(hipMemcpy(d_items.p, items, n * sizeof(c16_item), hipMemcpyHostToDevice),
               "hipMemcpy items", err)) {
        return false;
    }
    binary_kernel<<<dim3(blocks_for(n)), dim3(block_size)>>>(
        static_cast<const c16_item*>(d_items.p), n, static_cast<uint8_t*>(d_out.p), fmt);
    if (!launched("binary kernel", err)) {
        return false;
    }
    return check(hipMemcpy(out, d_out.p, out_bytes, hipMemcpyDeviceToHost),
                 "hipMemcpy words back", err);
}
