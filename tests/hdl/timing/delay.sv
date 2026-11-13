// Needs --timing: the delay is scheduled by the coroutine runtime.
module delay (
    output logic done
);
  initial begin
    done = 1'b0;
    #10 done = 1'b1;
  end
endmodule
