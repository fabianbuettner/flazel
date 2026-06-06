/* Freestanding (no libc) program. Two assertions in one target:
 *
 *  1. The #error below compile-fails unless the toolchain applied
 *     -ffreestanding (which is exactly what target.freestanding = true must
 *     do). __STDC_HOSTED__ is 1 in a hosted toolchain, 0 in a freestanding one.
 *  2. It links and runs with no libc: entry is _start (the bare-metal link
 *     posture drops the crt), and output goes out via raw x86_64 Linux
 *     syscalls, proving the freestanding compile + -nostdlib link + run path.
 */
#if __STDC_HOSTED__
#error "expected a freestanding toolchain: __STDC_HOSTED__ should be 0"
#endif

static long sys_write(int fd, const char *buf, unsigned long len) {
    long ret;
    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(1L), "D"((long)fd), "S"(buf), "d"(len)
                     : "rcx", "r11", "memory");
    return ret;
}

__attribute__((noreturn)) static void sys_exit(int code) {
    __asm__ volatile("syscall" : : "a"(60L), "D"((long)code) : "memory");
    __builtin_unreachable();
}

void _start(void) {
    static const char msg[] = "flazel freestanding ok\n";
    sys_write(1, msg, sizeof(msg) - 1);
    sys_exit(0);
}
