#include "big_objects/report.h"

#include <cstdio>

int report(const char* error) {
    std::puts(error ? error : "flazel big_objects ok");
    return error ? 1 : 0;
}
