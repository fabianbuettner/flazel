#ifndef C_ONLY_H
#define C_ONLY_H
// C, not C++: C++ does not convert void * implicitly.
static inline int *c_only(void *p) { return p; }
#endif
