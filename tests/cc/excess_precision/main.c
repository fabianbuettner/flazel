// a*b is 1 - 0x1p-60, which double rounds to 1 (flake.nix: excess-precision-mingw32).
#include <stdio.h>

static volatile double a = 1 + 0x1p-30, b = 1 - 0x1p-30, c = -1;

int main(void) {
    const double t = a * b;
    const double r = t + c;
    printf("%a\n", r);
    return 0;
}
