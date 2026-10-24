#include "clang_check/base.h"
int undeclared() { return static_cast<int>(base_words().size()); }
