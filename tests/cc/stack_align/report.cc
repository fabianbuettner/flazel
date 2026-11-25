#include "stack_align/report.h"

#include <cstdio>

// Out of line under LTO too, where flake.nix: stack-align-mingw32 disassembles it.
__attribute__((noinline)) int report(const char* error) {
    std::puts(error ? error : "flazel stack_align ok");
    return error ? 1 : 0;
}
