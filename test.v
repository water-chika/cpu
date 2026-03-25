`include "main.v"

module test();

reg clk;

main U0(.clk(clk));

initial begin
    $monitor("%g\tstall=%d, inst=%8d, reg0=%8d, reg1=%8d, reg2=%8d, reg3=%8d, reg4=%8d, reg5=%8d, reg6=%8d, reg7=%8d, IP=%8b",
        $time, U0.stall, U0.Inst, U0.registers[0], U0.registers[1], U0.registers[2], U0.registers[3],
        U0.registers[4], U0.registers[5], U0.registers[6], U0.registers[7], U0.IP);
    clk = 0;
    $readmemh("test.list", U0.program.mem);
    $readmemh("data.list", U0.data.mem);
    #640 $finish;
end

always
    #1 clk = ~clk;

endmodule
