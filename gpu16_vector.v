// gpu16's vector unit: sixteen lanes and the section 4.6 vector ALU.
//
// docs/gpu_isa.md section 1.1 fixes the wave at W = 16 lanes driven by one
// instruction stream, so this is not a second core.  It has no fetch, no PC
// and no control flow of its own: `gpu16.v` fetches and decodes, and hands
// the whole instruction word down here along with the exec mask and the two
// scalar operands a vector instruction can name.  What comes back up is the
// two things a vector instruction can write outside the VGPR file - a lane
// mask for `v_cmp_*` and one lane's value for `v_readlane`.
//
// SCOPE.  Section 4.6, plus the register file side of the per lane memory
// accesses of sections 4.8 and 4.9 - the cross lane address read, the store
// data read and the load return path, all of which are ports on this file
// driven by the memory unit in `gpu16.v`.
//
// Section 4.7's accumulator file is here too, for the reason section 2.3
// gives: `a[m]` in lane `n` is `C[m][n]`, so the accumulators are per lane
// state and belong beside the per lane state that already exists.  What is
// *not* here is the multiplier array, which section 7.3's arithmetic makes
// one per compute unit rather than one per wave - it is `gpu16_matrix.v`,
// instantiated once in `gpu16_cu.v` and arbitrated like the memory ports.
// This file supplies it operands and takes back one accumulator row, and
// `gpu16.v` holds the sixteen-cycle sequencer that walks the rows.
//
// THE REGISTER FILE is one flat array rather than sixteen separate ones:
//
//     vregs[{reg, lane}]   =   v[reg] in lane `lane`
//
// Register major, so that the sixteen lanes of one VGPR are contiguous.  That
// is the order a `+vexpect` file in `testgpu.v` is written in, and it is also
// the order the cross lane reads want: `v_readlane` and `v_bpermute` both
// read `v[Arg1]` from some other lane, which is one 16:1 multiplexer over a
// contiguous run - the same cheap structure section 4.7 relies on.
//
// EXEC.  Section 1.2: a lane whose exec bit is clear still *reads* its
// operands, so cross lane reads are well defined, but its registers are not
// written.  That rule is applied in exactly one place below - the guarded
// write at the end of the lane loop - rather than instruction by
// instruction, because there is exactly one rule.
//
// STYLE.  Same as gpu16.v: no delays, one clocked block, every piece of
// state written with a non blocking assignment, asynchronous reset.  The
// blocking assignments inside the lane loop are to combinational temporaries,
// which are read after being written and never across an edge.
module gpu16_vector #(
    parameter WAVE_WIDTH = 16
) (
    input clk,
    input reset,

    // High when the wave is retiring `inst` this cycle.  The vector unit
    // never stalls the wave on its own - section 1.4's interlock is trivially
    // satisfied while every vector instruction completes in one cycle - so
    // this is simply gpu16.v's issue signal.
    input issue,
    input [31:0] inst,

    // The wave's exec mask, bit per lane.
    input [15:0] exec,

    // s[Arg1] and s[Arg2], read in the scalar unit and passed down because
    // the vector unit has no port on the scalar register file.  Arg1 is the
    // source of `v_mov_s` and `v_writelane`, Arg2 of `v_add_s` and `v_mul_s`.
    input [31:0] s_src0,
    input [31:0] s_src1,

    // Section 4.1's sign extended 16 bit immediate, for `v_imm` and `v_addi`.
    input [31:0] imm,

    // `v_cmp_*`: the lane mask, already ANDed with exec as section 4.6
    // specifies.  Valid whenever `inst` is one of the four compares.
    output [15:0] cmp_mask,
    // `v_readlane`: v[Arg1] in lane Mod[3:0], read regardless of exec.
    output [31:0] readlane_value,

    // ------------------------------------------------ the memory unit's ports
    //
    // Sections 4.8 and 4.9 put the address of a per lane access in a VGPR and
    // its data in another, but the unit that turns sixteen addresses into
    // transactions lives in `gpu16.v` beside the memories.  These three ports
    // are what that unit needs from this register file, and they are sized
    // the way the hardware is: **one VGPR per cycle**, sixteen lanes wide.
    //
    // `vaddr` is v[Arg1] in all sixteen lanes, which is the address operand of
    // every per lane access, and it is the same cross lane read `v_readlane`
    // already does.
    output [511:0] vaddr,
    // `st_data` is v[st_reg] in all sixteen lanes.  A store walks its source
    // registers one per cycle through `st_reg`, so a `v_st16_g` reads its quad
    // over four cycles rather than through four register file ports - the
    // same argument section 4.8 makes for the load return path.
    input [3:0] st_reg,
    output [511:0] st_data,
    // The load return path.  `mem_mask` is already ANDed with exec by the
    // memory unit, so section 1.2's rule - a disabled lane's register is not
    // written - is applied here by the mask and nowhere else.
    input mem_write,
    input [3:0] mem_reg,
    input [15:0] mem_mask,
    input [511:0] mem_data,

    // ------------------------------------------------ the matrix unit's ports
    //
    // Section 4.7.  `gpu16.v` holds the sequencer - which row `m` of which
    // block is being walked this cycle, and whether the array granted it a
    // cycle - and these are the register file ports that sequencer drives.
    //
    // `mat_areg` names the A fragment VGPR and `mat_row` the lane to read it
    // from, and the two together are one 16:1 multiplexer over a contiguous
    // run of the file, exactly as `v_readlane` already is.  That is section
    // 4.7's structural claim - "because the unit walks one m per cycle, this
    // is a 16:1 multiplexer on a 32-bit value, not a crossbar" - and it is
    // the reason `mat_a` is 32 bits wide and not 512.
    input [3:0] mat_areg,
    input [3:0] mat_breg,
    input [3:0] mat_row,
    // Which of the 32 accumulators, i.e. {block, row}.
    input [4:0] mat_idx,
    output [31:0] mat_a,
    output [511:0] mat_b,
    output [511:0] mat_acc,
    // The row coming back, and the one cycle it is written in.  `mat_mask`
    // is the exec mask latched when the instruction issued: section 4.7 says
    // the A fragment rows of disabled lanes still participate but their
    // accumulators are not updated.
    input mat_write,
    input [15:0] mat_mask,
    input [511:0] mat_wdata
);

wire [7:0] opcode = inst[31:24];
wire [3:0] arg0 = inst[23:20];
wire [3:0] arg1 = inst[19:16];
wire [3:0] arg2 = inst[15:12];
wire [3:0] arg3 = inst[11:8];
wire [7:0] mod = inst[7:0];

reg [31:0] vregs[0:255];

// Section 2.3's accumulator file: 32 registers per lane, `a[m]` in lane `n`
// holding `C[m][n]`.  Accumulator major for the same reason the VGPRs are
// register major - the sixteen lanes of one accumulator are the *row* the
// matrix unit reads and writes whole, once per cycle, which is architectural
// requirement A1.
//
//     accs[{idx, lane}]   =   a[idx] in lane `lane`
//
// It is a separate array and not a slice of `vregs` because section 2.3 says
// so and gives the reason: this file needs one read and one write of a whole
// 16-lane row every cycle while the VGPR file is simultaneously feeding the
// same instruction its A and B fragments, and one file cannot do both
// without more ports than either needs alone.
reg [31:0] accs[0:511];

// ------------------------------------------------------------ cross lane reads
//
// One 32 bit value per lane, all of them v[Arg1].  Continuous assignments
// rather than an `always @*` block on purpose: `@*` over an array makes
// iverilog announce that it is sensitive to every word of it, and
// tests/lint_verilog.sh fails on any message at all.

wire [31:0] xlane[0:15];
wire [15:0] cmp_bit;

genvar g;
generate
    for (g = 0; g < 16; g = g + 1) begin : lane_read
        // g is a genvar, so this is a constant, and {arg1, LANE} is exactly
        // the eight bits the array index wants.
        localparam [3:0] LANE = g;
        assign xlane[g] = vregs[{arg1, LANE}];
        assign vaddr[32*g+:32] = xlane[g];
        assign st_data[32*g+:32] = vregs[{st_reg, LANE}];
        assign cmp_bit[g] = (opcode == 8'h5c) ? (xlane[g] != 32'b0)
                          : (opcode == 8'h5d) ? (xlane[g] == 32'b0)
                          : (opcode == 8'h5e) ? ($signed(xlane[g]) < 0)
                          : (opcode == 8'h5f) ? ($signed(xlane[g]) > 0)
                                              : 1'b0;
        // The matrix unit's two per lane reads: lane n's B fragment, and
        // lane n's word of the accumulator row being walked.
        assign mat_b[32*g+:32] = vregs[{mat_breg, LANE}];
        assign mat_acc[32*g+:32] = accs[{mat_idx, LANE}];
    end
endgenerate

// Section 4.7's cross lane A read, and the only place in the design where a
// value leaves the lane it lives in other than `v_readlane` and `v_bpermute`.
// One 32-bit word selected out of sixteen by the row counter: a 16:1
// multiplexer, which is the structural claim the area numbers rest on.
assign mat_a = vregs[{mat_areg, mat_row}];

// Section 4.6: the mask a compare writes is `exec & lanes(condition)`.  A
// disabled lane is therefore never reported as passing, whatever it holds.
assign cmp_mask = cmp_bit & exec;
assign readlane_value = xlane[mod[3:0]];

// ---------------------------------------------------------------- execute

integer l;
integer k;
integer i;

reg [31:0] src0;
reg [31:0] src1;
reg [31:0] src2;
reg [31:0] result;
reg write_v;
reg signed [31:0] dot;
reg signed [7:0] dot_a;
reg signed [7:0] dot_b;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        // Section 4.12 leaves the VGPRs undefined at launch.  Zero is a legal
        // choice for undefined and the only one a test can be written
        // against, which is the same call gpu16.v makes for the SGPRs.
        for (i = 0; i < 256; i = i + 1) begin
            vregs[i] <= 32'b0;
        end
        // The accumulators are launch state too, and section 4.12's "every
        // other register is undefined" covers them; zero is the choice a
        // test can be written against.  A kernel that means it still says
        // `acc_zero` or `mma_i8_z`.
        for (i = 0; i < 512; i = i + 1) begin
            accs[i] <= 32'b0;
        end
    end
    else begin
        for (l = 0; l < WAVE_WIDTH; l = l + 1) begin
            // Every lane reads its own operands, exec bit or not.
            src0 = vregs[{arg1, l[3:0]}];
            src1 = vregs[{arg2, l[3:0]}];
            src2 = vregs[{arg3, l[3:0]}];

            result = 32'b0;
            write_v = 1'b1;

            case (opcode)
                // -------------------------------------- 4.6 vector ALU
                8'h40: result = src0 & src1;
                8'h41: result = src0 | src1;
                8'h42: result = ~src0;
                8'h43: result = src0 ^ src1;
                8'h44: result = src0 + src1;
                8'h45: result = src0 - src1;
                8'h46: result = -src0;
                8'h47: result = src0 * src1;
                8'h48: result = src0 * src1 + src2;
                8'h49: result = src0 << src1;
                8'h4a: result = src0 >> src1;
                8'h4b: result = $signed(src0) >>> src1;
                8'h4c: result = src0;
                8'h4d: result = s_src0;
                8'h4e: result = imm;
                8'h4f: result = src0 + s_src1;
                8'h50: result = src0 * s_src1;
                8'h51: result = src0 << mod;
                8'h52: result = src0 >> mod;
                8'h53: result = $signed(src0) >>> mod;
                8'h54: result = ($signed(src0) < $signed(src1)) ? src0 : src1;
                8'h55: result = ($signed(src0) > $signed(src1)) ? src0 : src1;
                // v_dot4: four int8 multiply-accumulates in one lane, the
                // per lane sibling of mma_i8.  The bytes are sign extended
                // and the accumulator is the section 4.2 Arg3 operand.
                8'h56: begin
                    dot = $signed(src2);
                    for (k = 0; k < 4; k = k + 1) begin
                        dot_a = src0[8*k+:8];
                        dot_b = src1[8*k+:8];
                        dot = dot + dot_a * dot_b;
                    end
                    result = dot;
                end
                8'h57: result = {28'b0, l[3:0]};
                8'h58: result = src0 + imm;
                // v_writelane touches one lane, and only if that lane is
                // enabled - section 1.2's rule is not suspended for it.
                8'h5a: begin
                    result = s_src0;
                    write_v = (l[3:0] == mod[3:0]);
                end
                // v_bpermute: this lane's copy of v[Arg2] names the lane to
                // take v[Arg1] from.  The source lane's exec bit does not
                // matter; the destination lane's does.
                8'h5b: result = vregs[{arg1, src1[3:0]}];

                // acc_rd (section 4.7): one accumulator into a VGPR, this
                // lane's word of it.  `Mod` names one of the 32, so the
                // 16-entry Arg fields are not involved.  No wait is needed
                // before it, because gpu16.v does not issue it while the
                // matrix unit is still walking - section 1.4's interlock.
                8'h72: result = accs[{mod[4:0], l[3:0]}];

                // v_readlane (0x59) and the four compares (0x5c-0x5f) write a
                // scalar register, which is gpu16.v's file, not this one.
                // Everything else - the matrix unit, the memory instructions,
                // and every scalar instruction - writes no VGPR here either.
                default: write_v = 1'b0;
            endcase

            if (issue & write_v & exec[l[3:0]]) begin
                vregs[{arg0, l[3:0]}] <= result;
            end
        end

        // The memory unit's return path (section 4.8), one VGPR per cycle.
        // This is a second write port only in the sense that it is a second
        // `if`: `gpu16.v` holds `issue` low for every cycle a memory
        // instruction is still occupying the memory unit, so the loop above
        // and the loop below never fire in the same cycle.
        if (mem_write) begin
            for (l = 0; l < WAVE_WIDTH; l = l + 1) begin
                if (mem_mask[l[3:0]]) begin
                    vregs[{mem_reg, l[3:0]}] <= mem_data[32*l+:32];
                end
            end
        end

        // The accumulator file's one write port, section 2.3.  Two customers
        // and never both in the same cycle: the matrix unit writing the row
        // it walked this cycle, and `acc_wr` writing one row out of a VGPR.
        // gpu16.v does not issue an accumulator instruction while the matrix
        // unit is busy, so the `else` is a statement of that fact rather than
        // a priority.
        //
        // Both honour exec, which for `mma_i8` is section 4.7's sharp edge
        // written out: the A fragment row of a disabled lane still
        // participates - it was read through the cross lane mux, which knows
        // nothing about exec - but the accumulator of a disabled lane is not
        // updated.
        if (mat_write) begin
            for (l = 0; l < WAVE_WIDTH; l = l + 1) begin
                if (mat_mask[l[3:0]]) begin
                    accs[{mat_idx, l[3:0]}] <= mat_wdata[32*l+:32];
                end
            end
        end
        else if (issue & (opcode == 8'h73)) begin
            for (l = 0; l < WAVE_WIDTH; l = l + 1) begin
                if (exec[l[3:0]]) begin
                    accs[{mod[4:0], l[3:0]}] <= vregs[{arg1, l[3:0]}];
                end
            end
        end
    end
end

endmodule
