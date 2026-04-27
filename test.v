`include "cpu8.v"

module test();

reg clk;

cpu_inst8_data8 U0(.clk(clk));

initial begin
    $monitor("%g\tstall=%b, condition=%b, inst=%8b, reg0=%8b, reg1=%8b, reg2=%8b, reg3=%8b, reg4=%8b, reg5=%8b, reg6=%8b, reg7=%8b, IP=%8b",
        $time, U0.stall, U0.condition, U0.Inst, U0.registers[0], U0.registers[1], U0.registers[2], U0.registers[3],
        U0.registers[4], U0.registers[5], U0.registers[6], U0.registers[7], U0.IP);
    clk = 1;
    $readmemh("test.list", U0.program.mem);
    $readmemh("data.list", U0.data.mem);
    #6400 $finish;
end

always
    #5 clk = ~clk;

endmodule
