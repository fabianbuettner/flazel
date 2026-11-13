#include <cstdint>
#include <cstdio>
#include <memory>

#include "Vdelay.h"
#include "verilated.h"

int main(int argc, char** argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(argc, argv);
  auto dut = std::make_unique<Vdelay>(ctx.get());
  dut->eval();
  const int before = dut->done;
  while (dut->eventsPending()) {
    ctx->time(dut->nextTimeSlot());
    dut->eval();
  }
  dut->final();
  std::printf("before=%d after=%d time=%ju\n", before, dut->done,
              static_cast<std::uintmax_t>(ctx->time()));
  return before == 0 && dut->done == 1 && ctx->time() == 10 ? 0 : 1;
}
