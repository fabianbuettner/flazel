// GNU's asm and typeof keywords, which ISO C dialects turn off.
int gnu_keywords(void) {
    typeof(1) x = 1;
    asm volatile("" ::: "memory");
    return x;
}
