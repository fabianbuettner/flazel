// Drives the RTL and the model with the same random bits. Built against the
// real RTL it expects no mismatch; with EXPECT_MISMATCH, against a mutant, it
// expects some, which shows the comparison can fail at all.
#include <cstdint>
#include <cstdio>
#include <memory>
#include <random>

#include "Vscrambler.h"
#include "scrambler/scrambler_model.h"
#include "verilated.h"

#if VM_TRACE_FST
#include <cstdlib>
#include <filesystem>
#include <string>

#include "verilated_fst_c.h"
#endif

int main(int argc, char** argv) {
  auto ctx = std::make_unique<VerilatedContext>();
  ctx->commandArgs(argc, argv);
  auto dut = std::make_unique<Vscrambler>(ctx.get());
#if VM_TRACE_FST
  ctx->traceEverOn(true);
  auto fst = std::make_unique<VerilatedFstC>();
  dut->trace(fst.get(), 99);
  const char* tmp = std::getenv("TEST_TMPDIR");
  const std::string path = std::string(tmp ? tmp : ".") + "/scrambler.fst";
  fst->open(path.c_str());
#endif

  auto tick = [&] {
    dut->clk = 0;
    dut->eval();
    ctx->timeInc(1);
    dut->clk = 1;
    dut->eval();
#if VM_TRACE_FST
    fst->dump(ctx->time());
#endif
    ctx->timeInc(1);
  };

  dut->rst = 1;
  dut->en = 0;
  dut->din = 0;
  tick();
  dut->rst = 0;
  dut->en = 1;

  ScramblerModel model;
  std::mt19937 rng(42);
  const int n = 100000;
  int mismatches = 0;
  int ones = 0;
  for (int i = 0; i < n; ++i) {
    const int bit = static_cast<int>(rng() & 1);
    dut->din = bit;
    dut->eval();
    if (dut->dout != model.step(bit)) ++mismatches;
    ones += dut->dout;
    tick();
  }
  dut->final();
  std::printf("bits=%d mismatches=%d ones=%d\n", n, mismatches, ones);
  if (ones == 0 || ones == n) {
    std::printf("FAIL: constant output\n");
    return 1;
  }

#if VM_TRACE_FST
  fst->close();
  const auto size = std::filesystem::file_size(path);
  std::printf("fst=%s bytes=%ju\n", path.c_str(), static_cast<std::uintmax_t>(size));
  if (size == 0) return 1;
#endif

#ifdef EXPECT_MISMATCH
  return mismatches > 0 ? 0 : 1;
#else
  return mismatches == 0 ? 0 : 1;
#endif
}
