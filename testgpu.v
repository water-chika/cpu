`include "gpu16.v"

// Self checking testbench for gpu16's scalar unit, modelled on test16.v.
//
//   vvp simgpu +program=<hex file> +expect=<hex file> [+data=<hex file>]
//              [+cycles=<n>] [+arg_ptr=<n>] [+group_x=<n>] [+group_y=<n>]
//              [+wave_id=<n>] [+trace]
//
// The program file holds 32 bit instructions as 8 digit hex words and the
// expect file holds the 16 expected scalar registers (s0 first) as 8 digit
// hex words, where "xxxxxxxx" means "do not care".  $readmemh understands //
// comments, so a hand encoded program can carry its own disassembly.
//
// Unlike test16.v this insists the program reach s_endpgm.  cpu16 programs
// are allowed to run off their end into a field of zeroes; a gpu16 wave
// terminates explicitly, so a program that did not terminate has gone wrong
// even if the registers happen to look right.
module testgpu();

parameter PROGRAM_ADDR_WIDTH = 12;
parameter DATA_INDEX_WIDTH = 10;

reg clk;
reg reset;
integer i;
integer errors;
integer cycles;
integer ran;
integer has_data;
integer program_words;
integer data_words;
integer arg_ptr;
integer group_x;
integer group_y;
integer wave;

reg [1023:0] program_file;
reg [1023:0] data_file;
reg [1023:0] expect_file;
reg [31:0] expected[0:15];

gpu16_scalar #(
    .PROGRAM_ADDR_WIDTH(PROGRAM_ADDR_WIDTH),
    .DATA_INDEX_WIDTH(DATA_INDEX_WIDTH)
) U0 (
    .clk(clk),
    .reset(reset),
    .kernel_arg_ptr(arg_ptr[31:0]),
    .group_id_x(group_x[31:0]),
    .group_id_y(group_y[31:0]),
    .wave_id(wave[31:0]),
    .halted()
);

initial begin
    errors = 0;
    reset = 0;
    for (i = 0; i < 16; i = i + 1) begin
        expected[i] = 32'hxxxxxxxx;
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
    // The word counts only exist so that $readmemh is not asked to fill more
    // of the memory than the file covers, which it warns about.
    if (!$value$plusargs("program_words=%d", program_words)) begin
        program_words = 0;
    end
    if (!$value$plusargs("data_words=%d", data_words)) begin
        data_words = 0;
    end
    if (!$value$plusargs("cycles=%d", cycles)) begin
        cycles = 1000;
    end
    if (!$value$plusargs("arg_ptr=%d", arg_ptr)) begin
        arg_ptr = 0;
    end
    if (!$value$plusargs("group_x=%d", group_x)) begin
        group_x = 0;
    end
    if (!$value$plusargs("group_y=%d", group_y)) begin
        group_y = 0;
    end
    if (!$value$plusargs("wave_id=%d", wave)) begin
        wave = 0;
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
        $monitor("%g\tPC=%04h inst=%08h bubble=%b halt=%b | s0=%08h s1=%08h s2=%08h s3=%08h s4=%08h s5=%08h s6=%08h s7=%08h",
            $time, U0.PC, U0.Inst, U0.bubble, U0.halted,
            U0.registers[0], U0.registers[1], U0.registers[2], U0.registers[3],
            U0.registers[4], U0.registers[5], U0.registers[6], U0.registers[7]);
    end

    // reset is asynchronous, and the pulse is over before the first rising
    // edge at t=10, so the wave executes its first instruction there.
    clk = 1;
    reset = 1;
    #7 reset = 0;

    // Step one cycle at a time so that the run stops at s_endpgm instead of
    // burning the whole budget.  t = 7, 17, 27 ... is always in the low half
    // of the clock, well away from the edge being sampled.
    ran = 0;
    while (ran < cycles && U0.halted !== 1'b1) begin
        #10;
        ran = ran + 1;
    end

    if (U0.halted !== 1'b1) begin
        $display("TEST FAIL: %0s never reached s_endpgm in %0d cycles", program_file, cycles);
        $finish;
    end

    for (i = 0; i < 16; i = i + 1) begin
        if (^expected[i] !== 1'bx) begin
            if (U0.registers[i] !== expected[i]) begin
                $display("  MISMATCH: s%0d = %08h, expected %08h", i, U0.registers[i], expected[i]);
                errors = errors + 1;
            end
            else begin
                $display("  ok:       s%0d = %08h", i, expected[i]);
            end
        end
    end

    if (errors == 0) begin
        $display("TEST PASS: %0s halted after %0d cycles", program_file, ran);
    end
    else begin
        $display("TEST FAIL: %0d register mismatch(es) running %0s", errors, program_file);
    end
    $finish;
end

always
    #5 clk = ~clk;

endmodule
