// Defines _DEFAULT_SOURCE itself, as a bare macro.
#define _DEFAULT_SOURCE
#include <stdlib.h>

int default_source_setenv(void) { return setenv("FLAZEL_DEFAULT_SOURCE", "ok", 1); }
