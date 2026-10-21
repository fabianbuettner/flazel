// Threads in an external repository: needs the target's thread runtime and
// "-iquote ." (mcfgthread's atomic.h includes __FILE__).
#include "counter.h"

#include <mutex>
#include <thread>

int count_in_thread() {
    std::mutex mutex;
    int count = 0;
    std::thread worker([&] {
        const std::lock_guard<std::mutex> lock(mutex);
        ++count;
    });
    worker.join();
    return count;
}
