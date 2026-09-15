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
// SCOPE.  Section 4.6 and nothing else.  The matrix unit (4.7), the per lane
// global accesses (4.8) and LDS (4.9) also live in the vector datapath and
// are deliberately absent; opcodes belonging to them are not decoded here and
// still fall through to `gpu16.v`'s `unknown opcode` arm, so nothing silently
// pretends to implement them.
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
    output [31:0] readlane_value
);

wire [7:0] opcode = inst[31:24];
wire [3:0] arg0 = inst[23:20];
wire [3:0] arg1 = inst[19:16];
wire [3:0] arg2 = inst[15:12];
wire [3:0] arg3 = inst[11:8];
wire [7:0] mod = inst[7:0];

reg [31:0] vregs[0:255];

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
        assign cmp_bit[g] = (opcode == 8'h5c) ? (xlane[g] != 32'b0)
                          : (opcode == 8'h5d) ? (xlane[g] == 32'b0)
                          : (opcode == 8'h5e) ? ($signed(xlane[g]) < 0)
                          : (opcode == 8'h5f) ? ($signed(xlane[g]) > 0)
                                              : 1'b0;
    end
endgenerate

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
    end
end

endmodule
