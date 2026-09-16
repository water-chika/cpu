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


// The loader.  The program and the data are read into the testbench's own
// arrays and then clocked into the CPU through its load port, one word per
// cycle, with reset held high - which is what a JTAG or UART loader on a
// board would do.  Nothing here reaches into the CPU's hierarchy, so the
// path the tests exercise is the path a device would use.
reg prog_load_enable;
reg [7:0] prog_load_address;
reg [15:0] prog_load_data;
reg data_load_enable;
reg [7:0] data_load_address;
reg [7:0] data_load_data;
reg [15:0] progmem[0:255];
reg [7:0] datamem[0:255];
integer load_words;
integer w;

cpu_inst16_data8 U0(
    .clk(clk),
    .reset(reset),
    .prog_load_enable(prog_load_enable),
    .prog_load_address(prog_load_address),
    .prog_load_data(prog_load_data),
    .data_load_enable(data_load_enable),
    .data_load_address(data_load_address),
    .data_load_data(data_load_data)
);

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

    // Into the testbench's arrays first.  An entry the file did not cover
    // stays x and is never clocked in, which is why the word counts matter.
    for (i = 0; i < 256; i = i + 1) begin
        progmem[i] = 16'hxxxx;
        datamem[i] = 8'hxx;
    end
    if (program_words > 0) begin
        $readmemh(program_file, progmem, 0, program_words - 1);
    end
    else begin
        $readmemh(program_file, progmem);
        // No count given: load everything the file actually covered.
        program_words = 0;
        for (w = 0; w < 256; w = w + 1) begin
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
            for (w = 0; w < 256; w = w + 1) begin
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

    if ($test$plusargs("trace")) begin
        $monitor("%g\tstall=%b, inst=%16b, reg0=%8b, reg1=%8b, reg2=%8b, reg3=%8b, reg4=%8b, reg5=%8b, reg6=%8b, reg7=%8b, IP=%8b",
            $time, U0.stall, U0.Inst, U0.registers[0], U0.registers[1], U0.registers[2], U0.registers[3],
            U0.registers[4], U0.registers[5], U0.registers[6], U0.registers[7], U0.IP);
    end

    // The CPU has an asynchronous reset in place of the initial blocks it
    // used to have, so the testbench has to pulse it.  Reset is held high for the whole load, so the CPU drives neither
    // memory and the loader simply owns both ports.  The two are loaded in
    // parallel because they are independent ports.
    clk = 1;
    reset = 1;
    prog_load_enable = 1'b0;
    data_load_enable = 1'b0;
    prog_load_address = 8'b0;
    data_load_address = 8'b0;
    prog_load_data = 16'b0;
    data_load_data = 8'b0;

    load_words = (program_words > data_words) ? program_words : data_words;
    // t = 2, 12, 22 ... is well clear of the rising edges at 10, 20, 30 ...
    #2;
    for (w = 0; w < load_words; w = w + 1) begin
        prog_load_enable = (w < program_words);
        prog_load_address = w[7:0];
        prog_load_data = progmem[w];
        data_load_enable = (w < data_words);
        data_load_address = w[7:0];
        data_load_data = datamem[w];
        #10;
    end
    prog_load_enable = 1'b0;
    data_load_enable = 1'b0;

    // Exactly the original release phase, just 10*load_words later: the
    // pulse ends before a rising edge, so the number of instructions
    // executed in "cycles" cycles is what it always was.
    #5 reset = 0;
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
