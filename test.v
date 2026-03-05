`include "main.v"

module test();

reg clk;

main U0(.clk(clk));

initial begin
    $monitor("%g\tU0.IP=%8d", $time, U0.IP);
    clk = 0;
    #20 $finish;
end

always
    #1 clk = ~clk;

endmodule
