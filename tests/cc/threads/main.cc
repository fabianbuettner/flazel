// Threading from a library in another repository (see dep/counter.cc).
#include <cstdio>

#include "counter.h"

int main() {
    std::printf("%s\n", count_in_thread() == 1 ? "flazel cc ok" : "thread did not run");
    return 0;
}
