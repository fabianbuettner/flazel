// C++23 <print>, whose Windows console output mingw-w64 keeps in libstdc++exp
// (flake.nix: println-mingw*, stdcxxexp-mingw*).
#include <print>

int main() { std::println("flazel {} ok", "println"); }
