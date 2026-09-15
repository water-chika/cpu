#ifndef ASM_PIPELINE_HPP
#define ASM_PIPELINE_HPP

// The host half of the assembler: read the source, drive the per line stages
// on whichever backend was asked for, run the one serial scan that places
// addresses and resolves labels, and write the bytes out.
//
// Backends are chosen with environment variables rather than new command line
// options, because the command line of "asm" and "asm16" has to stay exactly
// what it was:
//
//   ASM_BACKEND=serial|threads|hip|auto   (default auto)
//   ASM_THREADS=<n>                       (default hardware_concurrency)
//
// Whatever the backend, the output bytes are identical; tests/backends.sh
// checks that rather than trusting it.

#include "asm_kernel.hpp"
#include "asm_hip.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <format>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

enum class asm_backend { serial, threads, hip };

// Where the time went, in seconds.  The benchmark prints these; the
// assemblers ignore them.
struct asm_stats {
    double split = 0;
    double classify = 0;
    double scan = 0;
    double resolve = 0;
    double encode = 0;
    size_t lines = 0;
    size_t statements = 0;
    size_t words = 0;
    size_t input_bytes = 0;
    unsigned threads = 1;
};

struct asm_options {
    bool hex = false;
    bool debug = false;
    bool sep_with_line = false;
    asm_backend backend = asm_backend::serial;
    unsigned threads = 1;
    // The CPU only has 256 instruction words.  The benchmark lifts the limit
    // so that it can time programs that are worth timing; nothing else does.
    uint32_t address_limit = 255;
};

// ------------------------------------------------------------- scheduling

// Run fn(begin, end) over [0, n) split into one chunk per thread.  One thread
// means no thread: the serial backend really does run on the calling thread.
template <class Fn>
inline void asm_parallel_for(size_t n, unsigned threads, Fn fn) {
    if (threads <= 1 || n < 2) {
        fn(size_t{0}, n);
        return;
    }
    unsigned used = static_cast<unsigned>(std::min<size_t>(threads, n));
    size_t chunk = (n + used - 1) / used;
    std::vector<std::thread> pool;
    pool.reserve(used - 1);
    for (unsigned t = 1; t < used; t++) {
        size_t begin = std::min(n, static_cast<size_t>(t) * chunk);
        size_t end = std::min(n, begin + chunk);
        if (begin < end) {
            pool.emplace_back([=] { fn(begin, end); });
        }
    }
    fn(size_t{0}, std::min(n, chunk));
    for (auto& t : pool) {
        t.join();
    }
}

// A block of trivially copyable records that is deliberately *not* zero
// filled when it is allocated.  Every one of these is written in full by the
// pass that follows, and at a few tens of megabytes the clearing costs as
// much as the real work does.
template <class T>
class asm_array {
public:
    void reset(size_t n) {
        storage_.reset(n != 0 ? new T[n] : nullptr);
        size_ = n;
    }
    T* data() { return storage_.get(); }
    const T* data() const { return storage_.get(); }
    size_t size() const { return size_; }
    T& operator[](size_t i) { return storage_[i]; }
    const T& operator[](size_t i) const { return storage_[i]; }

private:
    std::unique_ptr<T[]> storage_;
    size_t size_ = 0;
};

inline double asm_now() {
    using clock = std::chrono::steady_clock;
    return std::chrono::duration<double>(clock::now().time_since_epoch()).count();
}

// ------------------------------------------------------------- line split

// Split the buffer on '\n', the way std::getline did: a trailing newline does
// not make an extra empty line, and a file that ends without one still has a
// last line.  Done in parallel by cutting the buffer into ranges that each
// begin just after a newline, counting the lines in each range, and then
// filling every range from its own base, so the line numbering stays exact.
inline asm_array<asm_span> asm_split_lines(const std::vector<char>& buf, unsigned threads) {
    asm_array<asm_span> lines;
    if (buf.empty()) {
        lines.reset(0);
        return lines;
    }
    size_t n = buf.size();
    unsigned used = n < (1u << 16) ? 1u : std::max(1u, threads);

    std::vector<size_t> bounds(used + 1);
    bounds[0] = 0;
    bounds[used] = n;
    for (unsigned t = 1; t < used; t++) {
        size_t guess = n * t / used;
        const void* nl = std::memchr(buf.data() + guess, '\n', n - guess);
        bounds[t] = nl != nullptr
                    ? static_cast<size_t>(static_cast<const char*>(nl) - buf.data()) + 1
                    : n;
    }
    for (unsigned t = 1; t < used; t++) {
        bounds[t] = std::max(bounds[t], bounds[t - 1]);
    }

    std::vector<size_t> base(used + 1, 0);
    asm_parallel_for(used, used, [&](size_t begin, size_t end) {
        for (size_t t = begin; t < end; t++) {
            size_t count = 0;
            size_t i = bounds[t];
            size_t stop = bounds[t + 1];
            while (i < stop) {
                const void* nl = std::memchr(buf.data() + i, '\n', stop - i);
                if (nl == nullptr) {
                    count++;   // a last line with no newline of its own
                    break;
                }
                count++;
                i = static_cast<size_t>(static_cast<const char*>(nl) - buf.data()) + 1;
            }
            base[t + 1] = count;
        }
    });
    for (unsigned t = 0; t < used; t++) {
        base[t + 1] += base[t];
    }
    lines.reset(base[used]);
    asm_parallel_for(used, used, [&](size_t begin, size_t end) {
        for (size_t t = begin; t < end; t++) {
            size_t k = base[t];
            size_t i = bounds[t];
            size_t stop = bounds[t + 1];
            while (i < stop) {
                const void* nl = std::memchr(buf.data() + i, '\n', stop - i);
                size_t line_end = nl != nullptr
                                  ? static_cast<size_t>(static_cast<const char*>(nl) - buf.data())
                                  : stop;
                lines[k++] = asm_span{static_cast<uint32_t>(i),
                                      static_cast<uint32_t>(line_end - i)};
                i = line_end + 1;
            }
        }
    });
    return lines;
}
// ------------------------------------------------------------- reporting

struct asm_error {
    uint8_t code = ASM_OK;
    uint32_t line_number = 0;
    std::string detail;   // the offending token, when the message names one
    uint32_t count = 0;   // the token count, when the message names one
};

template <class ISA>
inline std::string asm_error_text(const asm_error& e) {
    std::string_view tool = ISA::tool;
    switch (e.code) {
    case ASM_ERR_LABEL_DUP:
        return std::format("{}: line {}: label '{}' defined twice\n", tool, e.line_number, e.detail);
    case ASM_ERR_TOO_BIG:
        return std::format("{}: line {}: the program does not fit in 256 instructions\n",
                           tool, e.line_number);
    case ASM_ERR_LA_TOKENS:
        return std::format("{}: line {}: expected 'la <dst> <label>', got {} token(s)\n",
                           tool, e.line_number, e.count);
    case ASM_ERR_LA_DST:
        return std::format("{}: line {}: 'la' destination '{}' is not a register\n",
                           tool, e.line_number, e.detail);
    case ASM_ERR_UNKNOWN_LABEL:
        return std::format("{}: line {}: unknown label '{}'\n", tool, e.line_number, e.detail);
    case ASM_ERR_NO_SCRATCH:
        return std::format("{}: line {}: 'la' needs a scratch register, "
                           "put a 'set_src1_dst1' before it\n", tool, e.line_number);
    case ASM_ERR_SCRATCH_IS_DST:
        return std::format("{}: line {}: 'la' destination '{}' is also the "
                           "src1/dst1 scratch register, pick another one\n",
                           tool, e.line_number, e.detail);
    case ASM_ERR_TOKENS:
        if constexpr (ISA::nargs == 1) {
            return std::format("{}: line {}: expected '<op> <arg>', got {} token(s)\n",
                               tool, e.line_number, e.count);
        }
        else {
            return std::format("{}: line {}: expected '<op> <arg0> <arg1> <arg2>', got {} token(s)\n",
                               tool, e.line_number, e.count);
        }
    case ASM_ERR_OPCODE:
        return std::format("{}: line {}: unknown opcode '{}'\n", tool, e.line_number, e.detail);
    case ASM_ERR_ARG:
        if constexpr (ISA::nargs == 1) {
            return std::format("{}: line {}: unknown argument '{}'\n", tool, e.line_number, e.detail);
        }
        else {
            return std::format("{}: line {}: unknown argument in '{}'\n", tool, e.line_number, e.detail);
        }
    case ASM_ERR_ARG_RANGE0:
    case ASM_ERR_ARG_RANGE1:
    case ASM_ERR_ARG_RANGE2:
        return std::format("{}: line {}: argument '{}' does not fit in 3 bits\n",
                           tool, e.line_number, e.detail);
    default:
        return std::format("{}: line {}: internal error\n", tool, e.line_number);
    }
}

// ------------------------------------------------------------- label table

// FNV-1a.  Small, and cheap enough that the parallel pass can hash every
// label it walks past and hand the serial insert a number instead of a
// string.
inline uint64_t asm_hash(const char* s, uint32_t len) {
    uint64_t h = 1469598103934665603ull;
    for (uint32_t i = 0; i < len; i++) {
        h ^= static_cast<unsigned char>(s[i]);
        h *= 1099511628211ull;
    }
    return h;
}

// An open addressed table from label name to address.
//
// std::unordered_map allocates a node per label and hashes the name again on
// every lookup.  With a few tens of thousands of labels that was the slowest
// thing left in the assembler, because inserting them is the one part of the
// scan that has to happen in program order.  This table is sized up front
// from the label count the counting pass already produced, stores names as
// slices of the source, and takes a precomputed hash.
class asm_label_table {
public:
    void reset(const char* base, size_t expected) {
        base_ = base;
        size_t capacity = 16;
        while (capacity < (expected + 1) * 2) {
            capacity <<= 1;
        }
        slots_.assign(capacity, slot{});
        mask_ = capacity - 1;
    }

    // False when the name is already defined, which is the "defined twice"
    // error the caller reports.
    bool insert(asm_span name, uint64_t hash, uint32_t address) {
        size_t i = static_cast<size_t>(hash) & mask_;
        while (slots_[i].used != 0) {
            if (equal(slots_[i], name, hash)) {
                return false;
            }
            i = (i + 1) & mask_;
        }
        slots_[i] = slot{name, address, hash, 1};
        return true;
    }

    bool find(asm_span name, uint64_t hash, uint32_t* out) const {
        size_t i = static_cast<size_t>(hash) & mask_;
        while (slots_[i].used != 0) {
            if (equal(slots_[i], name, hash)) {
                *out = slots_[i].address;
                return true;
            }
            i = (i + 1) & mask_;
        }
        return false;
    }

private:
    struct slot {
        asm_span name{0, 0};
        uint32_t address = 0;
        uint64_t hash = 0;
        uint8_t used = 0;
    };

    bool equal(const slot& s, asm_span name, uint64_t hash) const {
        return s.hash == hash && s.name.len == name.len &&
               std::memcmp(base_ + s.name.off, base_ + name.off, name.len) == 0;
    }

    std::vector<slot> slots_;
    size_t mask_ = 0;
    const char* base_ = nullptr;
};

// ------------------------------------------------------------- the pipeline

struct asm_result {
    bool ok = false;
    asm_error error;
    asm_array<uint8_t> output;
    std::vector<char> debug;
    asm_stats stats;
};

inline std::string_view asm_text(const std::vector<char>& buf, asm_span s) {
    return std::string_view(buf.data() + s.off, s.len);
}

// The cold path.  asm_line deliberately does not remember where a line's
// tokens were, because carrying that for every line costs more memory traffic
// than re-finding it on the few lines that need it: the ones that define a
// label, the one that failed, and every line at all under --debug.
struct asm_relexed {
    std::vector<asm_span> labels;
    std::vector<asm_span> tokens;
};

inline void asm_relex(const std::vector<char>& buf, asm_span line, asm_relexed& out) {
    out.labels.clear();
    out.tokens.clear();
    const char* s = buf.data() + line.off;
    uint32_t len = asm_code_length(s, line.len);
    uint32_t pos = 0;
    asm_span tok;
    bool have = asm_next_token(s, len, &pos, &tok);
    while (have && asm_is_label_definition(s + tok.off, tok.len)) {
        out.labels.push_back(asm_span{line.off + tok.off, tok.len - 1});
        have = asm_next_token(s, len, &pos, &tok);
    }
    while (have) {
        out.tokens.push_back(asm_span{line.off + tok.off, tok.len});
        have = asm_next_token(s, len, &pos, &tok);
    }
}

// Fill in the token an error message wants to quote.
template <class ISA>
inline void asm_detail_from_line(const std::vector<char>& buf, asm_span line, asm_error& e) {
    asm_relexed r;
    asm_relex(buf, line, r);
    auto token = [&](size_t i) -> std::string {
        return i < r.tokens.size() ? std::string(asm_text(buf, r.tokens[i])) : std::string();
    };
    switch (e.code) {
    case ASM_ERR_LA_DST:
    case ASM_ERR_SCRATCH_IS_DST:
        e.detail = token(1);
        break;
    case ASM_ERR_OPCODE:
        e.detail = token(0);
        break;
    case ASM_ERR_ARG:
        if constexpr (ISA::nargs == 1) {
            e.detail = token(1);
        }
        else {
            e.detail = std::format("{} {} {}", token(1), token(2), token(3));
        }
        break;
    case ASM_ERR_ARG_RANGE0:
    case ASM_ERR_ARG_RANGE1:
    case ASM_ERR_ARG_RANGE2:
        e.detail = token(1 + (e.code - ASM_ERR_ARG_RANGE0));
        break;
    default:
        break;
    }
}

// Stage one on the chosen backend: lex and parse every line.
template <class ISA>
inline bool asm_run_classify(const std::vector<char>& buf,
                             const asm_array<asm_span>& lines,
                             asm_array<asm_line>& out,
                             const asm_options& opt,
                             std::string* err) {
    out.reset(lines.size());
    if (opt.backend == asm_backend::hip) {
        return asm_hip_classify(ISA::word_bytes == 1 ? 8 : 16, buf.data(), buf.size(),
                                lines.data(), lines.size(), out.data(), err);
    }
    unsigned threads = opt.backend == asm_backend::threads ? opt.threads : 1;
    const asm_span* line = lines.data();
    asm_line* info = out.data();
    const char* base = buf.data();
    asm_parallel_for(lines.size(), threads, [=](size_t begin, size_t end) {
        for (size_t i = begin; i < end; i++) {
            asm_classify_line<ISA>(base, line[i], &info[i]);
        }
    });
    return true;
}

// Stage three on the chosen backend: encode every statement straight into its
// own slice of the output buffer.
template <class ISA>
inline bool asm_run_encode(const asm_statement* statements, size_t n,
                           asm_array<uint8_t>& out,
                           asm_format fmt,
                           const asm_options& opt,
                           std::string* err) {
    if (opt.backend == asm_backend::hip) {
        return asm_hip_encode(ISA::word_bytes == 1 ? 8 : 16, statements, n,
                              out.data(), out.size(), fmt, err);
    }
    unsigned threads = opt.backend == asm_backend::threads ? opt.threads : 1;
    uint8_t* bytes = out.data();
    asm_parallel_for(n, threads, [=](size_t begin, size_t end) {
        for (size_t i = begin; i < end; i++) {
            asm_encode_statement<ISA>(statements[i], bytes, fmt);
        }
    });
    return true;
}

// How a range of work is cut up between threads.  One chunk per thread, and
// one chunk altogether when the input is too small to be worth splitting.
struct asm_chunking {
    size_t chunk = 1;
    size_t count = 1;
    unsigned threads = 1;

    asm_chunking(size_t n, unsigned threads_in) {
        threads = n < (1u << 16) ? 1u : std::max(1u, threads_in);
        chunk = std::max<size_t>(1, (n + threads - 1) / threads);
        count = (n + chunk - 1) / chunk;
    }
    size_t begin(size_t c) const { return c * chunk; }
    size_t end(size_t c, size_t n) const { return std::min(n, begin(c) + chunk); }
};

// Where a line that defines labels ended up, so that the label table can be
// built afterwards without the scan itself having to be serial.
struct asm_label_site {
    asm_span name;
    uint64_t hash;
    uint32_t address;
    uint32_t line_number;
};

// Stage two: give every statement an address and build the label table.
//
// Laying out addresses looks serial - each statement starts where the last
// one ended - but it is only a running total, so it is done as a chunked
// prefix sum: every thread totals its own slice, the per slice totals are
// added up (there are as many of those as there are threads), and then every
// thread fills its slice in parallel from its own base.  The same pass
// compacts the lines that assemble into a dense statement array.
//
// What genuinely has to happen in order is inserting the labels, because
// "defined twice" is an ordered question, and choosing which of two errors to
// report.  Both are proportional to the number of labels, not to the number
// of lines.
template <class ISA>
inline size_t asm_scan(const std::vector<char>& buf,
                       const asm_array<asm_span>& lines,
                       const asm_array<asm_line>& info,
                       const asm_options& opt,
                       unsigned threads,
                       asm_array<asm_statement>& statements,
                       asm_label_table& labels,
                       asm_result& result) {
    size_t n = lines.size();
    asm_chunking cut(n, threads);

    std::vector<uint32_t> word_base(cut.count + 1, 0);
    std::vector<uint32_t> stmt_base(cut.count + 1, 0);
    asm_parallel_for(cut.count, cut.threads, [&](size_t begin, size_t end) {
        for (size_t c = begin; c < end; c++) {
            uint32_t words = 0;
            uint32_t count = 0;
            for (size_t i = cut.begin(c); i < cut.end(c, n); i++) {
                if (info[i].ntokens == 0) {
                    continue;
                }
                count++;
                words += asm_line_words<ISA>(info[i]);
            }
            word_base[c + 1] = words;
            stmt_base[c + 1] = count;
        }
    });
    for (size_t c = 0; c < cut.count; c++) {
        word_base[c + 1] += word_base[c];
        stmt_base[c + 1] += stmt_base[c];
    }
    statements.reset(stmt_base[cut.count]);
    result.stats.words = word_base[cut.count];

    std::vector<std::vector<asm_label_site>> sites(cut.count);
    asm_parallel_for(cut.count, cut.threads, [&](size_t begin, size_t end) {
        asm_relexed relexed;
        for (size_t c = begin; c < end; c++) {
            uint32_t address = word_base[c];
            size_t k = stmt_base[c];
            for (size_t i = cut.begin(c); i < cut.end(c, n); i++) {
                const asm_line& l = info[i];
                if (l.nlabels != 0) {
                    // Re-lex and hash here, while the line is in this core's
                    // cache, so that the ordered insert below is arithmetic
                    // rather than a walk back over the source text.
                    asm_relex(buf, lines[i], relexed);
                    for (asm_span name : relexed.labels) {
                        sites[c].push_back(asm_label_site{
                            name, asm_hash(buf.data() + name.off, name.len), address,
                            static_cast<uint32_t>(i) + 1});
                    }
                }
                if (l.ntokens == 0) {
                    continue;
                }
                asm_statement& s = statements[k++];
                s.line_index = static_cast<uint32_t>(i);
                s.address = address;
                s.target = 0;
                s.arg[0] = l.arg[0];
                s.arg[1] = l.arg[1];
                s.arg[2] = l.arg[2];
                s.opcode = l.opcode;
                s.is_la = l.is_la;
                s.pad[0] = s.pad[1] = s.pad[2] = 0;
                address += asm_line_words<ISA>(l);
            }
        }
    });
    size_t total = stmt_base[cut.count];

    // Addresses only go up, so the first statement that does not fit in the
    // CPU's program memory is found without looking at the rest.
    uint32_t too_big_line = 0;
    const asm_statement* over =
        std::partition_point(statements.data(), statements.data() + total,
                             [&](const asm_statement& s) {
                                 return s.address <= opt.address_limit;
                             });
    if (over != statements.data() + total) {
        too_big_line = over->line_index + 1;
    }

    size_t nlabels = 0;
    for (const auto& per_chunk : sites) {
        nlabels += per_chunk.size();
    }
    labels.reset(buf.data(), nlabels);
    for (const auto& per_chunk : sites) {
        for (const asm_label_site& site : per_chunk) {
            if (too_big_line != 0 && site.line_number > too_big_line) {
                break;
            }
            if (!labels.insert(site.name, site.hash, site.address)) {
                result.error = asm_error{ASM_ERR_LABEL_DUP, site.line_number,
                                         std::string(asm_text(buf, site.name)), 0};
                return total;
            }
        }
    }
    if (too_big_line != 0) {
        result.error = asm_error{ASM_ERR_TOO_BIG, too_big_line, {}, 0};
    }
    return total;
}

// Decide one statement: whether it is legal, and what address its "la" wants.
// Shared by the parallel sweep and by the serial re-check that builds the
// message for whichever statement turned out to be the first to fail.
template <class ISA>
inline uint8_t asm_check_statement(const std::vector<char>& buf,
                                   const asm_line& l,
                                   const asm_label_table& labels,
                                   int32_t* scratch,
                                   int32_t* target) {
    if (l.error != ASM_OK) {
        return l.error;
    }
    if (l.is_la) {
        uint32_t address = 0;
        if (!labels.find(l.name, asm_hash(buf.data() + l.name.off, l.name.len), &address)) {
            return ASM_ERR_UNKNOWN_LABEL;
        }
        if constexpr (ISA::has_scratch) {
            if (*scratch < 0) {
                return ASM_ERR_NO_SCRATCH;
            }
            if (*scratch == l.arg[0]) {
                return ASM_ERR_SCRATCH_IS_DST;
            }
        }
        *target = static_cast<int32_t>(address);
        return ASM_OK;
    }
    if constexpr (ISA::has_scratch) {
        if (ISA::is_scratch_setter(l.opcode)) {
            *scratch = l.arg[0];
        }
    }
    return ASM_OK;
}

// The rest of the scan: the checks that need the label table, plus the
// running src1/dst1 scratch register that cpu8's "la" needs.
//
// This is parallel too.  The label lookups are reads of a table nobody is
// writing any more, the scratch register is carried across chunks by the same
// prefix trick the address scan uses, and "which statement failed" is a
// minimum rather than a sequence - the first chunk that reports a failure
// holds the first failure, because the chunks are in program order.
//
// Returns the index of the statement that failed, or the statement count.
template <class ISA>
inline size_t asm_resolve(const std::vector<char>& buf,
                          const asm_array<asm_span>& lines,
                          const asm_array<asm_line>& info,
                          const asm_label_table& labels,
                          asm_array<asm_statement>& statements, size_t n,
                          unsigned threads,
                          asm_result& result) {
    if (n == 0) {
        return 0;
    }
    asm_chunking cut(n, threads);

    // The scratch register in force when each chunk starts.
    std::vector<int32_t> scratch_in(cut.count, -1);
    if constexpr (ISA::has_scratch) {
        std::vector<int32_t> last(cut.count, -1);
        asm_parallel_for(cut.count, cut.threads, [&](size_t begin, size_t end) {
            for (size_t c = begin; c < end; c++) {
                int32_t value = -1;
                for (size_t i = cut.begin(c); i < cut.end(c, n); i++) {
                    const asm_line& l = info[statements[i].line_index];
                    if (!l.is_la && l.error == ASM_OK && ISA::is_scratch_setter(l.opcode)) {
                        value = l.arg[0];
                    }
                }
                last[c] = value;
            }
        });
        for (size_t c = 1; c < cut.count; c++) {
            scratch_in[c] = last[c - 1] >= 0 ? last[c - 1] : scratch_in[c - 1];
        }
    }

    std::vector<size_t> failure(cut.count, n);
    asm_parallel_for(cut.count, cut.threads, [&](size_t begin, size_t end) {
        for (size_t c = begin; c < end; c++) {
            int32_t scratch = scratch_in[c];
            for (size_t i = cut.begin(c); i < cut.end(c, n); i++) {
                asm_statement& s = statements[i];
                int32_t target = 0;
                uint8_t code = asm_check_statement<ISA>(buf, info[s.line_index], labels,
                                                        &scratch, &target);
                if (code != ASM_OK) {
                    failure[c] = i;
                    break;
                }
                s.target = target;
            }
        }
    });
    size_t failed_at = n;
    for (size_t c = 0; c < cut.count; c++) {
        if (failure[c] < n) {
            failed_at = failure[c];
            break;
        }
    }
    if (failed_at == n) {
        return n;
    }

    // Rebuild the one failure with its message.  Walking the chunk again to
    // recover the scratch register costs nothing: it happens once, and only
    // when the program is about to be rejected.
    size_t c = failed_at / cut.chunk;
    int32_t scratch = scratch_in[c];
    int32_t target = 0;
    uint8_t code = ASM_OK;
    for (size_t i = cut.begin(c); i <= failed_at; i++) {
        code = asm_check_statement<ISA>(buf, info[statements[i].line_index], labels,
                                        &scratch, &target);
    }
    const asm_line& l = info[statements[failed_at].line_index];
    uint32_t line_number = statements[failed_at].line_index + 1;
    asm_error e{code, line_number, {}, l.ntokens};
    if (code == ASM_ERR_UNKNOWN_LABEL) {
        e.detail = std::string(asm_text(buf, l.name));
    }
    else {
        asm_detail_from_line<ISA>(buf, lines[statements[failed_at].line_index], e);
    }
    result.error = e;
    return failed_at;
}

// Reproduce the --debug trace of the original assembler, which printed one or
// two lines per statement as it encoded them, and stopped part way through
// the statement that failed.
template <class ISA>
inline void asm_write_debug(const std::vector<char>& buf,
                            const asm_array<asm_span>& lines,
                            const asm_array<asm_line>& info,
                            const asm_array<asm_statement>& statements,
                            size_t upto, bool failed, size_t total,
                            std::string& out) {
    asm_relexed r;
    auto token = [&](size_t i) -> std::string_view {
        return i < r.tokens.size() ? asm_text(buf, r.tokens[i]) : std::string_view();
    };
    auto source_line = [&]() {
        if constexpr (ISA::nargs == 1) {
            out += std::format("{},{}\n", token(0), token(1));
        }
        else {
            out += std::format("{},{},{},{}\n", token(0), token(1), token(2), token(3));
        }
    };
    for (size_t k = 0; k < upto; k++) {
        const asm_statement& s = statements[k];
        const asm_line& l = info[s.line_index];
        asm_relex(buf, lines[s.line_index], r);
        if (l.is_la) {
            out += std::format("la {} {} -> {}\n", token(1), token(2), s.target);
            continue;
        }
        source_line();
        if constexpr (ISA::nargs == 1) {
            out += std::format("{},{}\n", static_cast<int>(l.opcode), l.arg[0]);
        }
        else {
            out += std::format("{},{},{},{}\n", static_cast<int>(l.opcode),
                               l.arg[0], l.arg[1], l.arg[2]);
        }
    }
    if (!failed || upto >= total) {
        return;
    }
    // The statement that failed: the original printed the first of its two
    // debug lines before parsing the operands, so an operand error shows it.
    const asm_line& l = info[statements[upto].line_index];
    if (l.error < ASM_ERR_ARG || l.error > ASM_ERR_ARG_RANGE2) {
        return;
    }
    asm_relex(buf, lines[statements[upto].line_index], r);
    source_line();
}

// Assemble a whole source buffer.  This is what both the command line tools
// and the benchmark call.
template <class ISA>
inline asm_result asm_assemble(const std::vector<char>& buf, const asm_options& opt) {
    asm_result result;
    asm_format fmt{static_cast<uint8_t>(opt.hex ? 1 : 0),
                   static_cast<uint8_t>(ISA::word_bytes),
                   opt.sep_with_line ? '\n' : ',', 0};
    result.stats.input_bytes = buf.size();
    // The GPU backend still lexes nothing on the CPU, but the stages around
    // it - splitting lines, the scan - stay on the host, and there is no
    // reason to run those on one core just because the encode is elsewhere.
    unsigned host_threads = opt.backend == asm_backend::serial ? 1u : opt.threads;
    result.stats.threads = host_threads;

    double t0 = asm_now();
    asm_array<asm_span> lines = asm_split_lines(buf, host_threads);
    double t1 = asm_now();
    result.stats.lines = lines.size();

    asm_array<asm_line> info;
    std::string err;
    if (!asm_run_classify<ISA>(buf, lines, info, opt, &err)) {
        result.error = asm_error{ASM_OK, 0, err, 0};
        result.ok = false;
        return result;
    }
    double t2 = asm_now();

    asm_array<asm_statement> statements;
    asm_label_table labels;
    size_t total = asm_scan<ISA>(buf, lines, info, opt, host_threads,
                                 statements, labels, result);
    if (result.error.code != ASM_OK) {
        return result;   // a pass one error, before any --debug output
    }
    double t3 = asm_now();
    size_t failed_at = asm_resolve<ISA>(buf, lines, info, labels, statements, total,
                                        host_threads, result);
    double t4 = asm_now();
    result.stats.statements = total;

    std::string debug;
    if (opt.debug) {
        asm_write_debug<ISA>(buf, lines, info, statements, failed_at,
                             result.error.code != ASM_OK, total, debug);
        result.debug.assign(debug.begin(), debug.end());
    }

    // The original assembler wrote each word as it encoded it, so a program
    // that fails half way through still put the words before the failure on
    // stdout.  Keep that: encode everything up to the statement that failed.
    uint32_t emit_words = failed_at < total ? statements[failed_at].address
                                            : result.stats.words;

    result.output.reset(static_cast<size_t>(emit_words) * asm_bytes_per_word(fmt));
    if (!asm_run_encode<ISA>(statements.data(), failed_at, result.output, fmt, opt, &err)) {
        result.error = asm_error{ASM_OK, 0, err, 0};
        result.output.reset(0);
        return result;
    }
    double t5 = asm_now();

    result.stats.split = t1 - t0;
    result.stats.classify = t2 - t1;
    result.stats.scan = t3 - t2;
    result.stats.resolve = t4 - t3;
    result.stats.encode = t5 - t4;
    result.ok = result.error.code == ASM_OK;
    return result;
}

// ------------------------------------------------------------- driver

inline unsigned asm_default_threads() {
    unsigned n = std::thread::hardware_concurrency();
    return n == 0 ? 1u : n;
}

// Read the backend choice out of the environment.  "auto" stays serial for
// small inputs, where starting threads costs more than the work itself.
inline void asm_backend_from_env(asm_options& opt, size_t input_bytes) {
    const char* threads = std::getenv("ASM_THREADS");
    opt.threads = asm_default_threads();
    if (threads != nullptr) {
        int n = std::atoi(threads);
        if (n > 0) {
            opt.threads = static_cast<unsigned>(n);
        }
    }
    const char* backend = std::getenv("ASM_BACKEND");
    std::string_view name = backend != nullptr ? backend : "auto";
    if (name == "serial") {
        opt.backend = asm_backend::serial;
    }
    else if (name == "threads") {
        opt.backend = asm_backend::threads;
    }
    else if (name == "hip") {
        opt.backend = asm_backend::hip;
    }
    else {
        // Measured break even on a 24 core host: below roughly two megabytes
        // of source, waking the worker threads costs more than the work they
        // would take away, and at a few thousand lines the threaded path is
        // an order of magnitude slower than just doing it.  See the "bench"
        // target, which prints the same sweep.
        opt.backend = input_bytes >= (2u << 20) ? asm_backend::threads : asm_backend::serial;
    }
}

inline std::vector<char> asm_read_all(std::FILE* f) {
    std::vector<char> buf;
    char chunk[1 << 16];
    size_t n;
    while ((n = std::fread(chunk, 1, sizeof(chunk), f)) > 0) {
        buf.insert(buf.end(), chunk, chunk + n);
    }
    return buf;
}

template <class ISA>
inline int asm_main(int argc, const char* argv[]) {
    asm_options opt;
    for (int i = 1; i < argc; i++) {
        std::string_view a = argv[i];
        if (a == "--hex") {
            opt.hex = true;
        }
        else if (a == "--debug") {
            opt.debug = true;
        }
        else if (a == "--sep_with_line") {
            opt.sep_with_line = true;
        }
        else if (a == "--help") {
            std::fputs("Usage: asm [options]\n"
                       "Options:\n"
                       "  --hex             Output in hexadecimal format\n"
                       "  --debug           Enable debug output\n"
                       "  --sep_with_line   Separate output with new lines instead of commas\n"
                       "  --help            Show this help message\n", stdout);
            return 0;
        }
    }
    std::vector<char> buf = asm_read_all(stdin);
    asm_backend_from_env(opt, buf.size());
    asm_result result = asm_assemble<ISA>(buf, opt);
    if (!result.debug.empty()) {
        std::fwrite(result.debug.data(), 1, result.debug.size(), stderr);
    }
    // Whatever was assembled before a failure still goes out, the way the
    // original streaming assembler left it.
    if (result.output.size() != 0) {
        std::fwrite(result.output.data(), 1, result.output.size(), stdout);
    }
    if (!result.ok) {
        std::string text = result.error.code == ASM_OK
                           ? std::format("{}: {}\n", ISA::tool, result.error.detail)
                           : asm_error_text<ISA>(result.error);
        std::fwrite(text.data(), 1, text.size(), stderr);
        return 1;
    }
    return 0;
}

#endif  // ASM_PIPELINE_HPP
