// M_PI without a feature-test macro, and identifiers that GNU C++ dialects
// predefine as macros: both usable on mingw-w64 only with _GNU_SOURCE and ISO
// C++ (flake.nix: m-pi-mingw64, gnu-source).
#include <cmath>
#include <cstdio>

enum class Os { unix, linux, WIN32 };

int main() {
    const bool ok = M_PI > 3.14 && M_PI < 3.15 && static_cast<int>(Os::WIN32) == 2;
    std::printf("%s\n", ok ? "flazel m_pi ok" : "M_PI is wrong");
    return 0;
}
