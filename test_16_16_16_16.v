`include "cpu_16_16_16_16.v"

// Self checking testbench for cpu_16_16_16_16.
//
//   vvp sim +program=<hex file> +expect=<hex file>
//           [+data=<hex file>] [+mexpect=<hex file>]
//           [+program_words=<n>] [+data_words=<n>] [+mexpect_words=<n>]
//           [+cycles=<n>] [+trace]
//
// The program file holds 16 bit instructions as 4 digit hex words; the data
// file holds 16 bit *words* of data memory, so the word at index w covers
// byte addresses 2w and 2w+1 and the low byte is the even one; the expect
// file holds the sixteen register values (r0 first) as 4 digit hex, where
// "xxxx" means "do not care".
//
// Two things here that test16.v does not have, both deliberate:
//
//   * **the program has to halt.**  docs/cpu_16_16_16_16.md section 7 gives
//     this core a `halt` instruction, and this testbench treats a program
//     that has not halted by the end of its cycle budget as a failure - the
//     same rule gpu16 has for `s_endpgm`.  Without it, "the program ran off
//     into the weeds but the registers happened to look right" is a pass.
//   * **`+mexpect` checks data memory.**  A store test that only reads its
//     own stores back cannot see a load and a store that are wrong in the
//     same direction - a byte lane swapped in both, say - so the store tests
//     compare the array itself against words computed from the ISA document.
module test_16_16_16_16();

parameter PROGRAM_WORDS = 1 << 15;
parameter DATA_WORDS = 1 << 15;
parameter MEXPECT_WORDS = 64;

reg clk;
reg reset;
integer i;
integer errors;
integer cycles;
integer has_data;
integer has_mexpect;
integer program_words;
integer data_words;
integer mexpect_words;

reg [1023:0] program_file;
reg [1023:0] data_file;
reg [1023:0] expect_file;
reg [1023:0] mexpect_file;
reg [15:0] expected[0:15];
reg [15:0] mexpected[0:MEXPECT_WORDS-1];

// The loader.  As in test16.v, the program and the data are read into the
// testbench's own arrays and then clocked into the core through its load
// ports with reset held high, which is what a JTAG or UART loader on a board
// would do.  Nothing here reaches into the core's hierarchy to place a
// program, so the path the tests exercise is the path a device would use.
reg prog_load_enable;
reg [14:0] prog_load_address;
reg [15:0] prog_load_data;
reg data_load_enable;
reg [14:0] data_load_address;
reg [15:0] data_load_data;
reg [15:0] progmem[0:PROGRAM_WORDS-1];
reg [15:0] datamem[0:DATA_WORDS-1];
integer load_words;
integer w;

wire halted;

cpu_16_16_16_16 U0(
    .clk(clk),
    .reset(reset),
    .prog_load_enable(prog_load_enable),
    .prog_load_address(prog_load_address),
    .prog_load_data(prog_load_data),
    .data_load_enable(data_load_enable),
    .data_load_address(data_load_address),
    .data_load_data(data_load_data),
    .halted(halted)
);

initial begin
    errors = 0;
    reset = 0;
    for (i = 0; i < 16; i = i + 1) begin
        expected[i] = 16'hxxxx;
    end
    for (i = 0; i < MEXPECT_WORDS; i = i + 1) begin
        mexpected[i] = 16'hxxxx;
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
    has_mexpect = $value$plusargs("mexpect=%s", mexpect_file);
    // The word counts are optional: they only exist so that $readmemh is not
    // asked to fill more of an array than the file actually covers.
    if (!$value$plusargs("program_words=%d", program_words)) begin
        program_words = 0;
    end
    if (!$value$plusargs("data_words=%d", data_words)) begin
        data_words = 0;
    end
    if (!$value$plusargs("mexpect_words=%d", mexpect_words)) begin
        mexpect_words = 0;
    end
    if (!$value$plusargs("cycles=%d", cycles)) begin
        cycles = 300;
    end

    for (i = 0; i < PROGRAM_WORDS; i = i + 1) begin
        progmem[i] = 16'hxxxx;
    end
    for (i = 0; i < DATA_WORDS; i = i + 1) begin
        datamem[i] = 16'hxxxx;
    end
    if (program_words > 0) begin
        $readmemh(program_file, progmem, 0, program_words - 1);
    end
    else begin
        $readmemh(program_file, progmem);
        program_words = 0;
        for (w = 0; w < PROGRAM_WORDS; w = w + 1) begin
            if (^progmem[w] !== 1'bx) begin
                program_words = w + 1;
            end
        end
    end
    if (has_data) begin
        if (data_words > 0) begin
            $readmemh(data_file, datamem, 0, data_words - 1);
        end
        else begin
            $readmemh(data_file, datamem);
            data_words = 0;
            for (w = 0; w < DATA_WORDS; w = w + 1) begin
                if (^datamem[w] !== 1'bx) begin
                    data_words = w + 1;
                end
            end
        end
    end
    else begin
        data_words = 0;
    end
    $readmemh(expect_file, expected);
    if (has_mexpect) begin
        if (mexpect_words > 0) begin
            $readmemh(mexpect_file, mexpected, 0, mexpect_words - 1);
        end
        else begin
            $readmemh(mexpect_file, mexpected);
            mexpect_words = MEXPECT_WORDS;
        end
    end

    if ($test$plusargs("trace")) begin
        $monitor("%g\tPC=%h inst=%h flags(vcnz)=%b%b%b%b halted=%b  r0=%h r1=%h r2=%h r3=%h r4=%h r5=%h r6=%h r7=%h",
            $time, U0.PC, U0.Inst, U0.flag_v, U0.flag_c, U0.flag_n, U0.flag_z, halted,
            U0.registers[0], U0.registers[1], U0.registers[2], U0.registers[3],
            U0.registers[4], U0.registers[5], U0.registers[6], U0.registers[7]);
    end

    clk = 1;
    reset = 1;
    prog_load_enable = 1'b0;
    data_load_enable = 1'b0;
    prog_load_address = 15'b0;
    data_load_address = 15'b0;
    prog_load_data = 16'b0;
    data_load_data = 16'b0;

    load_words = (program_words > data_words) ? program_words : data_words;
    // t = 2, 12, 22 ... is well clear of the rising edges at 10, 20, 30 ...
    #2;
    for (w = 0; w < load_words; w = w + 1) begin
        prog_load_enable = (w < program_words);
        prog_load_address = w[14:0];
        prog_load_data = progmem[w];
        data_load_enable = (w < data_words);
        data_load_address = w[14:0];
        data_load_data = datamem[w];
        #10;
    end
    prog_load_enable = 1'b0;
    data_load_enable = 1'b0;

    // The release phase of test16.v: the pulse ends before a rising edge, so
    // the number of instructions executed in "cycles" cycles is exactly
    // "cycles" - a halted core simply stops using them.
    #5 reset = 0;
    #(cycles*10 + 5 - 7);

    if (!halted) begin
        $display("TEST FAIL: %0s never halted in %0d cycles", program_file, cycles);
        errors = errors + 1;
    end

    for (i = 0; i < 16; i = i + 1) begin
        if (^expected[i] !== 1'bx) begin
            if (U0.registers[i] !== expected[i]) begin
                $display("  MISMATCH: r%0d = %04h, expected %04h", i, U0.registers[i], expected[i]);
                errors = errors + 1;
            end
            else begin
                $display("  ok:       r%0d = %04h", i, expected[i]);
            end
        end
    end

    for (i = 0; i < mexpect_words; i = i + 1) begin
        if (^mexpected[i] !== 1'bx) begin
            if (U0.data.mem[i] !== mexpected[i]) begin
                $display("  MISMATCH: mem[%0d] = %04h, expected %04h",
                         i, U0.data.mem[i], mexpected[i]);
                errors = errors + 1;
            end
            else begin
                $display("  ok:       mem[%0d] = %04h", i, mexpected[i]);
            end
        end
    end

    if (errors == 0) begin
        $display("TEST PASS: %0s after %0d cycles", program_file, cycles);
    end
    else begin
        $display("TEST FAIL: %0d mismatch(es) running %0s", errors, program_file);
    end
    $finish;
end

always
    #5 clk = ~clk;

endmodule
