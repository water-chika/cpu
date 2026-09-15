`include "cpu16.v"

// Self checking testbench for the 16 bit instruction / 8 bit data CPU.
//
// Same plusarg interface as test.v:
//
//   vvp sim16 +program=<hex file> +expect=<hex file> [+data=<hex file>]
//             [+cycles=<n>] [+trace]
//
// The program file holds 16 bit instructions as 4 digit hex words, the data
// file holds 8 bit bytes, and the expect file holds the 8 expected register
// values (r0 first) as hex bytes, where "xx" means "do not care".
module test16();

reg clk;
reg reset;
integer i;
integer errors;
integer cycles;
integer has_data;
integer program_words;
integer data_words;

reg [1023:0] program_file;
reg [1023:0] data_file;
reg [1023:0] expect_file;
reg [7:0] expected[0:7];

cpu_inst16_data8 U0(.clk(clk), .reset(reset));

initial begin
    errors = 0;
    reset = 0;
    for (i = 0; i < 8; i = i + 1) begin
        expected[i] = 8'hxx;
    end

    if (!$value$plusargs("program=%s", program_file)) begin
        $display("TEST FAIL: no +program=<file> given");
        $finish;
    end
    if (!$value$plusargs("expect=%s", expect_file)) begin
        $display("TEST FAIL: no +expect=<file> given");
        $finish;
    end
    has_data = $value$plusargs("data=%s", data_file);
    // The word counts are optional: they only exist so that $readmemh is not
    // asked to fill more of the memory than the file actually covers.
    if (!$value$plusargs("program_words=%d", program_words)) begin
        program_words = 0;
    end
    if (!$value$plusargs("data_words=%d", data_words)) begin
        data_words = 0;
    end
    if (!$value$plusargs("cycles=%d", cycles)) begin
        cycles = 300;
    end

    if (program_words > 0) begin
        $readmemh(program_file, U0.program.mem, 0, program_words - 1);
    end
    else begin
        $readmemh(program_file, U0.program.mem);
    end
    if (has_data) begin
        if (data_words > 0) begin
            $readmemh(data_file, U0.data.mem, 0, data_words - 1);
        end
        else begin
            $readmemh(data_file, U0.data.mem);
        end
    end
    $readmemh(expect_file, expected);

    if ($test$plusargs("trace")) begin
        $monitor("%g\tstall=%b, inst=%16b, reg0=%8b, reg1=%8b, reg2=%8b, reg3=%8b, reg4=%8b, reg5=%8b, reg6=%8b, reg7=%8b, IP=%8b",
            $time, U0.stall, U0.Inst, U0.registers[0], U0.registers[1], U0.registers[2], U0.registers[3],
            U0.registers[4], U0.registers[5], U0.registers[6], U0.registers[7], U0.IP);
    end

    // The CPU has an asynchronous reset in place of the initial blocks it
    // used to have, so the testbench has to pulse it.  The pulse is over
    // before the first rising edge at t=10, which is why the number of
    // instructions executed in "cycles" cycles is exactly what it always was.
    clk = 1;
    reset = 1;
    #7 reset = 0;
    #(cycles*10 + 5 - 7);

    for (i = 0; i < 8; i = i + 1) begin
        if (^expected[i] !== 1'bx) begin
            if (U0.registers[i] !== expected[i]) begin
                $display("  MISMATCH: r%0d = %02h, expected %02h", i, U0.registers[i], expected[i]);
                errors = errors + 1;
            end
            else begin
                $display("  ok:       r%0d = %02h", i, expected[i]);
            end
        end
    end

    if (errors == 0) begin
        $display("TEST PASS: %0s after %0d cycles", program_file, cycles);
    end
    else begin
        $display("TEST FAIL: %0d register mismatch(es) running %0s", errors, program_file);
    end
    $finish;
end

always
    #5 clk = ~clk;

endmodule
