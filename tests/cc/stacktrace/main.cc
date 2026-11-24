// C++23 <stacktrace>, which libstdc++ keeps in libstdc++exp (flake.nix:
// stacktrace-*, stdcxxexp-*). Windows traces: README.md, Windows.
#include <iostream>
#include <stacktrace>
#include <string>

int main() {
    const auto trace = std::stacktrace::current();
    std::cerr << trace << '\n';
#if defined(__USING_SJLJ_EXCEPTIONS__)
    // SJLJ unwinding walks no frames.
    const bool expected = true;
#elif defined(_WIN32)
    // libbacktrace names no frames.
    const bool expected = !trace.empty();
#else
    const bool expected = !trace.empty() && trace[0].description() == "main";
#endif
    if (expected) {
        std::cout << "flazel stacktrace ok\n";
    } else {
        std::cout << "flazel stacktrace of " << trace.size() << " frames, top frame '"
                  << (trace.empty() ? std::string{} : trace[0].description()) << "'\n";
    }
}
