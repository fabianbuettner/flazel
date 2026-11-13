#pragma once

#include <cstdint>

// Bit-exact model of scrambler.sv.
class ScramblerModel {
 public:
  int step(int din) {
    int out = din ^ ((state_ >> 17) & 1) ^ ((state_ >> 22) & 1);
    state_ = ((state_ << 1) | static_cast<uint32_t>(out)) & 0x7FFFFFu;
    return out;
  }

 private:
  uint32_t state_ = 0;
};
