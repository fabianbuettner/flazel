// Asks for POSIX.1-2001 only, which leaves the BSD name strlcpy to the program.
#define _POSIX_C_SOURCE 200112L
#include <string.h>

static size_t strlcpy(char *dst, const char *src, size_t size) {
    const size_t len = strlen(src);
    if (size != 0) {
        const size_t n = len < size ? len : size - 1;
        memcpy(dst, src, n);
        dst[n] = '\0';
    }
    return len;
}

size_t posix_c_source_copy(char *dst, const char *src, size_t size) { return strlcpy(dst, src, size); }
