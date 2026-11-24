// POSIX use from a library in another repository (see dep/posix.c).
#include <stdio.h>

#include "posix.h"

int main(void) {
    const char *value = posix_setenv_value();
    if (value == NULL) {
        return 1;
    }
    printf("flazel posix %s\n", value);
    return 0;
}
