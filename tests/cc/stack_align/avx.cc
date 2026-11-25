// A 32-byte-aligned vector passed by value, as Highway's Vec256, from frames
// 16 bytes apart (flake.nix: stack-align-mingw64).
#include <immintrin.h>

#include "stack_align/report.h"

struct Vec {
    __m256i raw;
};

__attribute__((noinline, target("avx2"))) int lane_sum(Vec v) {
    alignas(32) int lanes[8];
    _mm256_store_si256(reinterpret_cast<__m256i*>(lanes), v.raw);
    int sum = 0;
    for (const int lane : lanes) sum += lane;
    return sum;
}

// Win64 passes v as a pointer to a copy in this frame, which GCC moves with
// vmovdqa although the ABI aligns the stack to 16 bytes only.
__attribute__((noinline, target("avx2"))) int doubled_sum(const int* in) {
    Vec v{_mm256_loadu_si256(reinterpret_cast<const __m256i*>(in))};
    v.raw = _mm256_add_epi32(v.raw, v.raw);
    return lane_sum(v);
}

__attribute__((noinline)) int doubled_sum_below(const int* in, int bytes) {
    volatile char* const pad = static_cast<char*>(__builtin_alloca(bytes));
    if (bytes > 0) pad[0] = 0;
    return doubled_sum(in);
}

int main() {
    if (!__builtin_cpu_supports("avx2")) return report("no AVX2");
    const int in[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    constexpr int pads[] = {0, 16};
    for (const int bytes : pads) {
        if (doubled_sum_below(in, bytes) != 72) return report("wrong sum");
    }
    return report(nullptr);
}
