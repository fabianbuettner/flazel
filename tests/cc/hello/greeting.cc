#include "hello/greeting.h"

#include <cstdarg>
#include <string>

// Variadic join: exercises <cstdarg> (stdarg.h from the compiler resource dir)
// alongside libstdc++ <string>. A missing or mismatched builtin-header path in
// the generated toolchain shows up here as a compile failure.
static std::string join(int count, ...) {
    std::va_list args;
    va_start(args, count);
    std::string result;
    for (int i = 0; i < count; ++i) {
        if (i) {
            result += " ";
        }
        result += va_arg(args, const char *);
    }
    va_end(args);
    return result;
}

std::string greeting() {
    return join(3, "flazel", "cc", "ok");
}
