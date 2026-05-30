#include <cstdio>
#include <string>

#include "hello/greeting.h"

// Minimal cc_test with no external test framework (keeps the BCR dependency set
// small). Returns non-zero on mismatch so `bazel test` and a direct run both
// report failure.
int main() {
    const std::string actual = greeting();
    const std::string expected = "flazel cc ok";
    if (actual != expected) {
        std::printf("FAIL: expected \"%s\", got \"%s\"\n", expected.c_str(), actual.c_str());
        return 1;
    }
    return 0;
}
