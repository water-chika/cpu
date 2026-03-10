`include "main.v"

module test();

reg clk;

main U0(.clk(clk));

initial begin
    $monitor("%g\tU0.IP=%8d, reg0=%8d, reg1=%8d, reg2=%8d, reg3=%8d, reg4=%8d, reg5=%8d, reg6=%8d, reg7=%8d, inst=%8b",
        $time, U0.IP, U0.registers[0], U0.registers[1], U0.registers[2], U0.registers[3],
        U0.registers[4], U0.registers[5], U0.registers[6], U0.registers[7], U0.Inst);
    clk = 0;
    U0.program_memory[0] = 8'b01011_001; // imm reg0, 1      //----------start
    U0.program_memory[1] = 8'b01001_001; // mov reg1, reg0   // reg7 = 32
    U0.program_memory[2] = 8'b01100_101; // shl reg0, 5      //
    U0.program_memory[3] = 8'b01001_111; // mov reg7, reg0   //----------end
    U0.program_memory[4] = 8'b01011_001; // mov0 reg0, 1     //----------start reg1 += 1
    U0.program_memory[5] = 8'b00100_001; // add reg1, reg0   //----------end
    U0.program_memory[6] = 8'b01010_111; // mov0 reg0, reg7  //----------start
    U0.program_memory[7] = 8'b01001_010; // mov reg2, reg0   // reg2 = reg7 - reg1
    U0.program_memory[8] = 8'b01010_001; // mov0 reg0, reg1  //
    U0.program_memory[9] = 8'b00101_010; // sub reg2, reg0   //----------end
    U0.program_memory[10] = 8'b01011_100; // imm reg0, 4     //----------start if (reg2==0) goto 4;
    U0.program_memory[11] = 8'b01001_011; // mov reg3, reg0  //
    U0.program_memory[12] = 8'b01010_010; // mov0 reg0, reg2 //
    U0.program_memory[13] = 8'b10000_011; // bz reg3         //----------end
    #640 $finish;
end

always
    #1 clk = ~clk;

endmodule
