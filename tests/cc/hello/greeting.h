#pragma once

#include <string>

// Joins `count` C-strings with single spaces. Implemented with C varargs so
// the build must pull stdarg.h from the compiler's builtin/resource headers
// (clang-lib for Clang toolchains, gcc-lib for GCC) on top of libstdc++.
std::string greeting();
