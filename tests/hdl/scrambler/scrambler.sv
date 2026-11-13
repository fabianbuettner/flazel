// Self-synchronizing scrambler, 1 + x^-18 + x^-23.
module scrambler (
    input  logic clk,
    input  logic rst,
    input  logic en,
    input  logic din,
    output logic dout
);
  logic [22:0] state;

  assign dout = din ^ state[17] ^ state[22];

  always_ff @(posedge clk) begin
    if (rst) state <= '0;
    else if (en) state <= {state[21:0], dout};
  end
endmodule
