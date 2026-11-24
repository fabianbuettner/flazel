// POSIX declarations without a feature-test macro, compiled in an external
// repository: visible as c_flags removes __STRICT_ANSI__, hidden with it
// (flake.nix: posix-gcc, posix-strict).
#include "posix.h"

#include <stdlib.h>
#include <time.h>

const char *posix_setenv_value(void) {
    struct tm tm;
    const time_t epoch = 0;
    if (setenv("FLAZEL_POSIX", "ok", 1) != 0 || gmtime_r(&epoch, &tm) == NULL || tm.tm_year != 70) {
        return NULL;
    }
    return getenv("FLAZEL_POSIX");
}
