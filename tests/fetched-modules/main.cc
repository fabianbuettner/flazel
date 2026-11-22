#include <cstdio>

#ifdef USE_LZ4
#include <lz4.h>
static const char *compressor() { return LZ4_versionString(); }
#else
#include <zlib.h>
static const char *compressor() { return zlibVersion(); }
#endif

int main() {
    std::printf("flazel fetched modules ok: %s\n", compressor());
    return 0;
}
