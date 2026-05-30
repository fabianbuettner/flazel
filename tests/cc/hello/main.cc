#include <cstdio>

#include "hello/greeting.h"

int main() {
    std::printf("%s\n", greeting().c_str());
    return 0;
}
