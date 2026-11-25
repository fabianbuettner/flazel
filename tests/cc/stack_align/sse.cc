// An SSE value spilled across a call, from frames 4-byte but not 16-byte
// aligned, as Win32 allows (flake.nix: stack-align-mingw32).
#include <emmintrin.h>

#include "stack_align/report.h"

void (*volatile hook)(int*) = [](int*) {};

// GCC spills v to a 16-byte-aligned slot with movaps.
__attribute__((noinline, target("sse2"))) int spill(const int* in) {
    int out[4];
    __m128i v = _mm_loadu_si128(reinterpret_cast<const __m128i*>(in));
    v = _mm_add_epi32(v, v);
    hook(out);
    v = _mm_add_epi32(v, _mm_loadu_si128(reinterpret_cast<const __m128i*>(in)));
    _mm_storeu_si128(reinterpret_cast<__m128i*>(out), v);
    return out[0] + out[1] + out[2] + out[3];
}

// fn(arg), called with the stack pointer `below` bytes under a 16-byte boundary.
extern "C" int call_below(int (*fn)(const int*), const int* arg, int below);
asm(R"(
    .text
    .globl _call_below
_call_below:
    pushl %ebp
    movl %esp, %ebp
    andl $-16, %esp
    subl 16(%ebp), %esp
    subl $12, %esp
    pushl 12(%ebp)
    call *8(%ebp)
    leave
    ret
)");

int main() {
    if (!__builtin_cpu_supports("sse2")) return report("no SSE2");
    const int in[4] = {1, 2, 3, 4};
    constexpr int belows[] = {0, 4, 8, 12};
    for (const int below : belows) {
        if (call_below(spill, in, below) != 30) return report("wrong sum");
    }
    return report(nullptr);
}
