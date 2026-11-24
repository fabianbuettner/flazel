#include <stacktrace>

int main() { return static_cast<int>(std::stacktrace::current().size()); }
