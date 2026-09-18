`include "gpu16_cu.v"

// Self checking testbench for gpu16, modelled on test16.v.
//
// What is instantiated is a whole compute unit, because that is the unit the
// ISA describes: the LDS and the global port are shared by the workgroup and
// `s_barrier` is a statement about waves other than this one.  +waves says
// how many of the four wave slots to launch and defaults to 1, which is the
// configuration every single-wave test runs in and in which every grant is
// unopposed - so a one wave program behaves, cycle for cycle, exactly as it
// did when gpu16.v contained its own memory.
//
// The registers that are checked are wave 0's.  A multi wave program that
// wants to say something about wave 3 has to get the answer to wave 0, which
// is what the LDS and global memory are for and is a more honest test than
// reaching into another wave's register file from the testbench.
//
//   vvp simgpu +program=<hex file> +expect=<hex file> [+vexpect=<hex file>]
//              [+data=<hex file>]
//              [+mexpect=<hex file> +mexpect_word=<n> +mexpect_words=<n>]
//              [+cycles=<n>] [+arg_ptr=<n>] [+group_x=<n>] [+group_y=<n>]
//              [+wave_id=<n>] [+waves=<n>] [+trace] [+perf]
//
// The program file holds 32 bit instructions as 8 digit hex words and the
// expect file holds the 16 expected scalar registers (s0 first) as 8 digit
// hex words, where "xxxxxxxx" means "do not care".  $readmemh understands //
// comments, so a hand encoded program can carry its own disassembly.
//
// +vexpect is the same thing for the vector register file: 256 words, v0
// first, and within a VGPR lane 0 first, which is gpu16_vector.v's own
// `vregs[{reg, lane}]` order.  Sixteen words to a line is therefore one line
// per VGPR across the wave, which is the shape the answer is easiest to read
// in.  A test that does not pass +vexpect checks no VGPR at all, which is why
// the five scalar-era programs needed no new expectation file.
//
// +mexpect is the same idea for global memory, and it is what a kernel whose
// answer is a matrix needs: the sixteen scalar registers cannot hold 4096
// words of result, and a kernel that checksummed its own output into a
// register would be marking its own homework.  The file holds the expected
// 32 bit words of the region starting at word +mexpect_word, "xxxxxxxx" for
// do not care, and a word the kernel never wrote is x in the memory and
// therefore a mismatch against any real expectation.
//
// +perf prints the cycle count and the final scalar registers as "PERF"
// lines, for a kernel that read its own counters with `s_rd_sys`.  It is
// deliberately only a *print*: nothing here compares a performance number,
// because the measurement is worthless unless the answer was right, and the
// pass or fail of this simulation is about the answer.  The band check lives
// in tests/run_gpu_perf.sh, which reads these lines only after the
// correctness run has passed.
//
// The exec mask deliberately has no plusarg of its own.  A program that wants
// its final mask checked ends with `s_rd_exec s15` and puts the answer in the
// scalar expectation file - section 4.5 already provides the instruction, and
// a test that goes through the ISA proves the ISA works.
//
// Unlike test16.v this insists the program reach s_endpgm.  cpu16 programs
// are allowed to run off their end into a field of zeroes; a gpu16 wave
// terminates explicitly, so a program that did not terminate has gone wrong
// even if the registers happen to look right.
module testgpu();

parameter PROGRAM_ADDR_WIDTH = 12;
// Global memory lives *outside* the compute unit here, so this is the size of
// the testbench's stand-in for off-chip memory rather than a statement about
// the hardware.  2^18 words is 1 MiB, which is what section 7.3's largest
// kernel, `gemm256`, moves; the on-chip default of 1024 words (4 KiB) could
// not hold any of section 7's benchmarks at all, which is why the port
// exists (docs/fpga_bringup.md 4.7).
parameter DATA_INDEX_WIDTH = 18;

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
reg [1023:0] vexpect_file;
reg [31:0] expected[0:15];
reg [31:0] vexpected[0:255];
integer has_vexpect;
reg [1023:0] mexpect_file;
integer has_mexpect;
integer mexpect_word;
integer mexpect_words;
integer mismatches;
integer lane;
integer vreg;
integer waves;

// The loader.  The program is read into the testbench's own array and then
// clocked into the compute unit through its `prog_load_*` port, one
// instruction word per cycle, with reset held high.  It used to be four
// hierarchical `$readmemh` calls straight into `U0.wg[N].w_inst.program.mem`,
// which is not something a device can do - and which hid the fact that the
// instruction memory had no write port at all (docs/fpga_bringup.md 2.2a).
// The port writes all four waves at once, because all four run one program.
reg prog_load_enable;
reg [PROGRAM_ADDR_WIDTH-1:0] prog_load_address;
reg [31:0] prog_load_data;
reg [31:0] progmem[0:(1<<PROGRAM_ADDR_WIDTH)-1];
integer w;

// The global memory, and its loader.  `gpu16_cu` is built with
// EXTERNAL_GMEM = 1, so the array is the testbench's: this is the stand-in
// for whatever a board would put on the other side of that port, and being
// outside the compute unit is the entire point - it is how a working set
// bigger than an FPGA's block RAM becomes possible.
//
// It is loaded the same way the program is, through the port, one aligned
// 64 byte block per cycle with reset held high.  It used to be a
// `$readmemh(data_file, U0.data.mem)` straight into the compute unit's
// hierarchy, which is not something a device can do.
reg [31:0] datamem[0:(1<<DATA_INDEX_WIDTH)-1];
reg data_load_enable;
reg [17:0] data_load_block;
reg [511:0] data_load_data;
integer blk;
integer word;
integer data_blocks;

wire [17:0] cu_gmem_block_index;
wire cu_gmem_write_enable;
wire [63:0] cu_gmem_byte_enable;
wire [511:0] cu_gmem_in_block;
wire [511:0] gmem_out_block;

// The loader owns the port while it is enabled; the compute unit owns it
// afterwards.  Nothing arbitrates, because nothing needs to: the loader only
// runs while reset is high and a wave in reset issues nothing.
wire [17:0] gmem_block_index = data_load_enable ? data_load_block : cu_gmem_block_index;
wire gmem_write_enable = data_load_enable ? 1'b1 : cu_gmem_write_enable;
wire [63:0] gmem_byte_enable = data_load_enable ? {64{1'b1}} : cu_gmem_byte_enable;
wire [511:0] gmem_in_block = data_load_enable ? data_load_data : cu_gmem_in_block;

gpu16_gmem #(
    .WORD_INDEX_WIDTH(DATA_INDEX_WIDTH)
) gmem (
    .clk(clk),
    .block_index(gmem_block_index[DATA_INDEX_WIDTH-5:0]),
    .write_enable(gmem_write_enable),
    .byte_enable(gmem_byte_enable),
    .in_block(gmem_in_block),
    .out_block(gmem_out_block)
);

gpu16_cu #(
    .PROGRAM_ADDR_WIDTH(PROGRAM_ADDR_WIDTH),
    .DATA_INDEX_WIDTH(DATA_INDEX_WIDTH),
    .EXTERNAL_GMEM(1)
) U0 (
    .clk(clk),
    .reset(reset),
    .kernel_arg_ptr(arg_ptr[31:0]),
    .group_id_x(group_x[31:0]),
    .group_id_y(group_y[31:0]),
    .wave_id_base(wave[31:0]),
    .waves(waves[2:0]),
    .halted(),
    .prog_load_enable(prog_load_enable),
    .prog_load_address(prog_load_address),
    .prog_load_data(prog_load_data),
    .gmem_block_index(cu_gmem_block_index),
    .gmem_write_enable(cu_gmem_write_enable),
    .gmem_byte_enable(cu_gmem_byte_enable),
    .gmem_in_block(cu_gmem_in_block),
    .gmem_out_block(gmem_out_block)
);

initial begin
    errors = 0;
    reset = 0;
    for (i = 0; i < 16; i = i + 1) begin
        expected[i] = 32'hxxxxxxxx;
    end
    for (i = 0; i < 256; i = i + 1) begin
        vexpected[i] = 32'hxxxxxxxx;
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
    has_vexpect = $value$plusargs("vexpect=%s", vexpect_file);
    has_mexpect = $value$plusargs("mexpect=%s", mexpect_file);
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
    if (!$value$plusargs("waves=%d", waves)) begin
        waves = 1;
    end
    if (!$value$plusargs("mexpect_word=%d", mexpect_word)) begin
        mexpect_word = 0;
    end
    if (!$value$plusargs("mexpect_words=%d", mexpect_words)) begin
        mexpect_words = 0;
    end

    // Into the testbench's own array first; the clocking in happens below,
    // after reset has been asserted.
    for (w = 0; w < (1 << PROGRAM_ADDR_WIDTH); w = w + 1) begin
        progmem[w] = 32'hxxxxxxxx;
    end
    if (program_words > 0) begin
        $readmemh(program_file, progmem, 0, program_words - 1);
    end
    else begin
        $readmemh(program_file, progmem);
        // No count given: load everything the file actually covered.
        program_words = 0;
        for (w = 0; w < (1 << PROGRAM_ADDR_WIDTH); w = w + 1) begin
            if (^progmem[w] !== 1'bx) begin
                program_words = w + 1;
            end
        end
    end
    // Into the testbench's own array first, like the program; the clocking in
    // through the port happens below, after reset has been asserted.
    if (has_data) begin
        if (data_words > 0) begin
            $readmemh(data_file, datamem, 0, data_words - 1);
        end
        else begin
            $readmemh(data_file, datamem);
            data_words = 0;
            for (word = 0; word < (1 << DATA_INDEX_WIDTH); word = word + 1) begin
                if (^datamem[word] !== 1'bx) begin
                    data_words = word + 1;
                end
            end
        end
    end
    $readmemh(expect_file, expected);
    if (has_vexpect) begin
        $readmemh(vexpect_file, vexpected);
    end

    if ($test$plusargs("trace")) begin
        $monitor("%g\tPC=%04h inst=%08h bubble=%b halt=%b exec=%04h | s0=%08h s1=%08h s2=%08h s3=%08h s4=%08h s5=%08h s6=%08h s7=%08h",
            $time, U0.wg[0].w_inst.PC, U0.wg[0].w_inst.Inst, U0.wg[0].w_inst.bubble, U0.halted, U0.wg[0].w_inst.exec,
            U0.wg[0].w_inst.registers[0], U0.wg[0].w_inst.registers[1], U0.wg[0].w_inst.registers[2], U0.wg[0].w_inst.registers[3],
            U0.wg[0].w_inst.registers[4], U0.wg[0].w_inst.registers[5], U0.wg[0].w_inst.registers[6], U0.wg[0].w_inst.registers[7]);
    end

    // reset is asynchronous and is held high for the whole load, so no wave
    // is fetching while the loader owns the instruction memory's port.
    clk = 1;
    reset = 1;
    prog_load_enable = 1'b0;
    prog_load_address = {PROGRAM_ADDR_WIDTH{1'b0}};
    prog_load_data = 32'b0;
    data_load_enable = 1'b0;
    data_load_block = 18'b0;
    data_load_data = 512'b0;

    // One word per cycle.  t = 2, 12, 22 ... is well clear of the rising
    // edges at 10, 20, 30 ...
    #2;
    prog_load_enable = 1'b1;
    for (w = 0; w < program_words; w = w + 1) begin
        prog_load_address = w[PROGRAM_ADDR_WIDTH-1:0];
        prog_load_data = progmem[w];
        #10;
    end
    prog_load_enable = 1'b0;

    // Then the data image, one 64 byte block per cycle on the same schedule.
    // A partially covered last block is written whole; the words the file did
    // not cover are x, which is what they would have been anyway.
    data_blocks = (data_words + 15) / 16;
    if (has_data && data_blocks > 0) begin
        data_load_enable = 1'b1;
        for (blk = 0; blk < data_blocks; blk = blk + 1) begin
            data_load_block = blk[17:0];
            for (word = 0; word < 16; word = word + 1) begin
                data_load_data[32*word+:32] = datamem[blk*16 + word];
            end
            #10;
        end
        data_load_enable = 1'b0;
    end

    // The same release phase as before, one clock per loaded word and block:
    // the pulse is over before a rising edge, so the wave executes its first
    // instruction on the next one and `ran` counts exactly the cycles it
    // used to.
    #5 reset = 0;

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
            if (U0.wg[0].w_inst.registers[i] !== expected[i]) begin
                $display("  MISMATCH: s%0d = %08h, expected %08h", i, U0.wg[0].w_inst.registers[i], expected[i]);
                errors = errors + 1;
            end
            else begin
                $display("  ok:       s%0d = %08h", i, expected[i]);
            end
        end
    end

    if (has_vexpect) begin
        for (vreg = 0; vreg < 16; vreg = vreg + 1) begin
            for (lane = 0; lane < 16; lane = lane + 1) begin
                i = vreg * 16 + lane;
                if (^vexpected[i] !== 1'bx) begin
                    if (U0.wg[0].w_inst.vector.vregs[i] !== vexpected[i]) begin
                        $display("  MISMATCH: v%0d lane %0d = %08h, expected %08h",
                            vreg, lane, U0.wg[0].w_inst.vector.vregs[i], vexpected[i]);
                        errors = errors + 1;
                    end
                    else begin
                        $display("  ok:       v%0d lane %0d = %08h", vreg, lane, vexpected[i]);
                    end
                end
            end
        end
    end

    // The memory result.  datamem has done its job as the input image by
    // now, so the expectation is read back into it rather than into a second
    // array of a million words.  Only the first ten mismatches are printed:
    // a kernel that got the tiling wrong misses thousands, and the first few
    // say which corner of the tile moved just as well as all of them.
    if (has_mexpect) begin
        $readmemh(mexpect_file, datamem, 0, mexpect_words - 1);
        mismatches = 0;
        for (word = 0; word < mexpect_words; word = word + 1) begin
            if (^datamem[word] !== 1'bx) begin
                if (gmem.mem[mexpect_word + word] !== datamem[word]) begin
                    if (mismatches < 10) begin
                        $display("  MISMATCH: memory word %0d = %08h, expected %08h",
                            mexpect_word + word, gmem.mem[mexpect_word + word],
                            datamem[word]);
                    end
                    mismatches = mismatches + 1;
                end
            end
        end
        if (mismatches == 0) begin
            $display("  ok:       %0d memory words from word %0d",
                mexpect_words, mexpect_word);
        end
        else begin
            $display("  %0d of %0d memory words differ", mismatches, mexpect_words);
            errors = errors + mismatches;
        end
    end

    if ($test$plusargs("perf")) begin
        $display("PERF cycles %0d", ran);
        for (i = 0; i < 16; i = i + 1) begin
            $display("PERF s%0d %0d", i, U0.wg[0].w_inst.registers[i]);
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
