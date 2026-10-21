// std::thread and std::mutex need the target's thread runtime.
#include <cstdio>
#include <mutex>
#include <thread>

int main() {
    std::mutex mutex;
    int count = 0;
    std::thread worker([&] {
        const std::lock_guard<std::mutex> lock(mutex);
        ++count;
    });
    worker.join();
    std::printf("%s\n", count == 1 ? "flazel cc ok" : "thread did not run");
    return 0;
}
