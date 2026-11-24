// M_PI without a feature-test macro, which mingw-w64 hides under __STRICT_ANSI__.
#include <math.h>
#include <stdio.h>

int main(void) {
    const int ok = M_PI > 3.14 && M_PI < 3.15;
    printf("%s\n", ok ? "flazel m_pi ok" : "M_PI is wrong");
    return 0;
}
