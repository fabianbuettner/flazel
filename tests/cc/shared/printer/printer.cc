#include "shared/printer/printer.h"

#include <cstdio>

// stdout is a libc data symbol: using it in a shared object needs -fPIC.
void print_line(const char* text) {
    std::fputs(text, stdout);
    std::fputc('\n', stdout);
}
