// gpu16's matrix unit: the 64 int8 MACs of docs/gpu_isa.md section 4.7.
//
// "One instruction is 1024 MACs (16 x 16 x 4).  The hardware is 64 int8 MACs
// wide (16 lanes x 4 k) and the instruction occupies the matrix unit for 16
// cycles, one accumulator row per cycle."  That sentence is this module: 64
// multipliers, sixteen four-input adder trees and sixteen accumulate adders,
// used once per cycle for one value of `m`.
//
// It is purely combinational and holds no state, because none of the state
// belongs to it.  Section 2.3 puts the accumulators in a *per wave* file -
// 32 registers x 16 lanes x 4 B, 2 KiB a wave - while section 7.3's arithmetic
// makes the multiplier array itself one per *compute unit*: four waves issuing
// 16 `mma_i8` each give "1024 matrix cycles per workgroup iteration" against
// 324 issue slots, which is 4 x 256 and not 256, so the four waves are queueing
// for one array rather than each owning one.  So the array lives in
// `gpu16_cu.v` beside the other shared resources and is arbitrated exactly
// like the two memory ports: a wave asks, is granted, and advances one
// accumulator row.  The operands and the accumulator row arrive from whichever
// wave holds the grant and the result goes back to it in the same cycle.
//
// WHAT IS DELIBERATELY NOT HERE.  The 16:1 multiplexer that reads the A
// fragment across lanes is in `gpu16_vector.v`, on the register file it
// selects from, because that is where the sixteen candidate values are.  This
// module sees the *one* 32-bit A fragment that the mux already chose, which
// is section 4.7's whole point: the unit walks one `m` per cycle, so the A
// operand crosses lanes through a 16:1 mux and never through a 16x16
// crossbar.  A crossbar version of this design would have a [511:0] a_frag
// port here instead of a [31:0] one; that it does not is the structural
// claim, visible in the port list.
module gpu16_matrix (
    // v[Arg1] read from lane `m`, the A fragment row for the accumulator row
    // being walked this cycle: four packed int8, k = 0..3 from the low byte
    // up.  One 32-bit value for the whole array - see above.
    input [31:0] a_frag,

    // v[Arg2] read per lane: lane n holds the B fragment column n, four
    // packed int8 for the same k = 0..3.
    input [511:0] b_frag,

    // The accumulator row, sixteen lanes of int32, and the same row updated.
    // Section 2.3's architectural requirement A1: 64 B in and 64 B out every
    // cycle, which is what makes `mma_i8` 16 cycles and not 32.
    input [511:0] acc_in,

    // High for `mma_i8_z` (section 4.7, opcode 0x74): D = A * B rather than
    // D += A * B.  It is a property of the instruction and not of the row,
    // because every one of the sixteen rows is written exactly once, so
    // forcing the addend to zero for the whole instruction is the same thing
    // as overwriting.
    input zero_acc,

    output [511:0] acc_out
);

// Sixteen lanes, four MACs each.  `genvar` rather than an `always @*` block
// over the whole 512-bit vector: tests/lint_verilog.sh fails on any iverilog
// message at all, and a sensitivity list over a wide part select is one of
// the things it complains about.
genvar n;
generate
    for (n = 0; n < 16; n = n + 1) begin : lane
        wire signed [7:0] a0 = a_frag[7:0];
        wire signed [7:0] a1 = a_frag[15:8];
        wire signed [7:0] a2 = a_frag[23:16];
        wire signed [7:0] a3 = a_frag[31:24];

        wire signed [7:0] b0 = b_frag[32*n+:8];
        wire signed [7:0] b1 = b_frag[32*n+8+:8];
        wire signed [7:0] b2 = b_frag[32*n+16+:8];
        wire signed [7:0] b3 = b_frag[32*n+24+:8];

        // Section 4.7: `sext8(vA.byte[k]) * sext8(vB.byte[k])`, summed over
        // the four k of one instruction.  Each product is at most 16384 in
        // magnitude and the sum of four at most 65536, so the 32-bit
        // intermediate cannot overflow and neither can the accumulate: the
        // section's own claim is that int32 survives a K of 65536.
        wire signed [31:0] dot = $signed({{24{a0[7]}}, a0}) * $signed({{24{b0[7]}}, b0})
                               + $signed({{24{a1[7]}}, a1}) * $signed({{24{b1[7]}}, b1})
                               + $signed({{24{a2[7]}}, a2}) * $signed({{24{b2[7]}}, b2})
                               + $signed({{24{a3[7]}}, a3}) * $signed({{24{b3[7]}}, b3});

        wire [31:0] addend = zero_acc ? 32'b0 : acc_in[32*n+:32];

        assign acc_out[32*n+:32] = addend + dot;
    end
endgenerate

endmodule
