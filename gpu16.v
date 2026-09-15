`include "memory.v"
`include "gpu16_vector.v"

// gpu16: one wave of the machine in docs/gpu_isa.md.
//
// docs/gpu_isa.md section 6.3 decision 5 settles that this is a widened
// cpu16.v rather than a new core, and section 4.13 writes out what "widened"
// means.  All six of its rows are here:
//
//   registers       8 x 8 bit   ->  16 x 32 bit
//   select fields   3 bits      ->  4 bits
//   PC              8 bit       ->  16 bit, word addressed
//   data address    8 bit       ->  24 bit
//   immediate       8 bit       ->  16 bit, sign extended
//   instruction     16 bit      ->  32 bit, 8 bit opcode
//
// What is inherited from cpu16.v is the control skeleton - a PC that
// increments unless something redirects it, one flat `case (opcode)`, and a
// single register write back - and the opcode numbers, which section 4.3
// deliberately keeps identical wherever the two machines share an operation.
// The branch block really is cpu16's decimal 32-36 as gpu16's 0x20-0x24.
//
// SCOPE.  Sections 4.3 (scalar ALU), 4.4 (scalar control flow, including the
// two exec-mask branches), 4.5 (exec mask control), 4.6 (vector ALU, in
// gpu16_vector.v) and the three wave control opcodes from 4.10 that a
// program cannot do without, plus s_ld_g from 4.8 because it is the only
// scalar memory instruction and it is what the 24 bit data address exists
// for.  There is still no LDS (4.9), no matrix unit (4.7) and no per lane
// memory access (the rest of 4.8), so every opcode belonging to those falls
// through to the `unknown opcode` arm.  Nothing here guesses at their
// behaviour.
//
// SIMT, in one always block.  Section 1.1 gives the wave one PC, one fetch
// and one decode driving sixteen copies of the datapath, so the vector unit
// below is an instance, not a second core: it is handed the same instruction
// word this block decoded, in the same cycle, and the only feedback is the
// lane mask a v_cmp_* writes and the one lane value v_readlane reads.
// Divergence is entirely software managed (section 1.3) - there is no
// reconvergence stack and no per-lane PC anywhere in this file, and the only
// way exec ever changes is an instruction from section 4.5 changing it.
//
// STYLE.  Same rules as the post clean-up cpu16.v: no delays, every
// sequential register written with a non blocking assignment from one clocked
// block, and an asynchronous reset.
module gpu16 #(
    // The architectural program counter is 16 bits wide.  PROGRAM_ADDR_WIDTH
    // is how much of that this instance actually decodes; a simulation does
    // not want a 64 Ki word array it will never touch.
    parameter PROGRAM_ADDR_WIDTH = 12,
    // Likewise: the architectural data address is 24 bits (section 4.13), and
    // DATA_INDEX_WIDTH is how many 32 bit words this instance implements.
    parameter DATA_INDEX_WIDTH = 10
) (
    input clk,
    input reset,

    // Section 4.12, kernel launch state.  s0, s1 and s2 are loaded from these
    // by reset; s_rd_sys reads the same three back.
    input [31:0] kernel_arg_ptr,
    input [31:0] group_id_x,
    input [31:0] group_id_y,
    input [31:0] wave_id,

    // High once s_endpgm has retired.  The wave issues nothing more.
    output halted
);

// Waves per workgroup, lanes per wave and bytes of LDS per workgroup, as
// section 4.3's s_rd_sys table fixes them.  They are parameters rather than
// literals so that the numbers live in one place when the rest of the machine
// arrives.
parameter NUM_WAVES = 4;
parameter WAVE_WIDTH = 16;
parameter LDS_SIZE = 8192;

reg [15:0] PC;
reg halted_r;
assign halted = halted_r;

// Section 1.4 and 4.4: a taken branch costs a fixed 3 cycle bubble.  This is
// the analogue of cpu16's `stall`, done with a counter rather than a flag
// because the cost is more than one cycle.  A branch that is not taken does
// not redirect the PC and so does not bubble.
reg [1:0] bubble;

wire issue = (bubble == 2'b0) & ~halted_r;

integer i;

// ---------------------------------------------------------------- fetch

wire [PROGRAM_ADDR_WIDTH-1:0] program_address = PC[PROGRAM_ADDR_WIDTH-1:0];
wire [31:0] Inst;

memory #(
    .DATA_WIDTH(32),
    .ADDR_WIDTH(PROGRAM_ADDR_WIDTH)
) program (
    .clk(clk),
    .write_enable(1'b0),
    .enable(1'b1),
    .address(program_address),
    .in_data(32'b0),
    .out_data(Inst)
);

// ---------------------------------------------------------------- decode
//
// Section 4.1:
//
//   |1f .. 18|17 .. 14|13 .. 10|f .. c|b .. 8|7 .. 0|
//   | Opcode |  Arg0  |  Arg1  | Arg2 | Arg3 |  Mod |
//
// and the immediate forms reinterpret {Arg2, Arg3, Mod} as one signed 16 bit
// immediate at [15:0].

wire [7:0] opcode = Inst[31:24];
wire [3:0] arg0 = Inst[23:20];
wire [3:0] arg1 = Inst[19:16];
wire [3:0] arg2 = Inst[15:12];
wire [7:0] mod = Inst[7:0];
wire [15:0] imm16 = Inst[15:0];
wire [31:0] imm = {{16{imm16[15]}}, imm16};

reg [31:0] registers[0:15];

wire [31:0] dst_value = registers[arg0];
wire [31:0] src0_value = registers[arg1];
wire [31:0] src1_value = registers[arg2];

// ---------------------------------------------------------------- exec mask
//
// Section 1.2: one 16 bit register, bit l enabling lane l, 0xFFFF at launch.
// It is a wave register and not a lane register, so it lives here beside the
// PC rather than in the vector unit, and section 4.5's six instructions are
// decoded here for the same reason.  Section 2.1 says a mask occupies bits
// [15:0] of an SGPR and that mask producing instructions zero bits [31:16],
// which is why every read of it below is zero extended rather than merged.

reg [15:0] exec;

wire [15:0] cmp_mask;
wire [31:0] readlane_value;

gpu16_vector #(
    .WAVE_WIDTH(WAVE_WIDTH)
) vector (
    .clk(clk),
    .reset(reset),
    .issue(issue),
    .inst(Inst),
    .exec(exec),
    // s[Arg1] and s[Arg2].  The vector unit has no port on this register
    // file, so the two scalar operands a vector instruction may name are
    // read here and passed down.
    .s_src0(src0_value),
    .s_src1(src1_value),
    .imm(imm),
    .cmp_mask(cmp_mask),
    .readlane_value(readlane_value)
);

// The instruction after this one.  Section 4.3 and 4.4 define s_addpc,
// s_call and every `_i` branch against it, and the PC is word addressed.
wire [15:0] PC_next = PC + 16'b1;

// ---------------------------------------------------------------- global memory
//
// s_ld_g is the one scalar memory instruction.  Section 1.4 says memory
// results are *not* interlocked and that s_waitcnt_g is the only thing that
// makes a load's result visible, so a program has to write
//
//     s_ld_g s3, s0, 8
//     s_waitcnt_g 0
//     ... use s3 ...
//
// This implementation completes a global load in a single cycle, which
// satisfies "at most Mod operations outstanding" trivially and therefore
// makes s_waitcnt_g a no-op for now.  There is deliberately no forwarding
// path from the load write back into the same edge's decode, so a program
// that omits the s_waitcnt_g does not accidentally work here and then fail
// once the real outstanding-operation queue exists.

reg [23:0] gmem_address;
reg [3:0] gmem_dst;
reg gmem_read;
wire [31:0] gmem_out;

memory #(
    .DATA_WIDTH(32),
    .ADDR_WIDTH(DATA_INDEX_WIDTH)
) data (
    .clk(clk),
    .write_enable(1'b0),
    .enable(1'b1),
    // The data address is a 24 bit *byte* address and a scalar word is 4
    // bytes, so the word index drops the low two bits.  This instance
    // implements only the low DATA_INDEX_WIDTH words of that space.
    .address(gmem_address[DATA_INDEX_WIDTH+1:2]),
    .in_data(32'b0),
    .out_data(gmem_out)
);

wire [23:0] gmem_effective = src1_value[23:0] + {16'b0, mod};

// ---------------------------------------------------------------- system registers

reg [31:0] perf_cycles;
reg [31:0] perf_instrs;
reg [31:0] perf_gmem_bytes;

reg [31:0] sys_value;
always @* begin
    case (mod)
        8'd0: sys_value = wave_id;
        8'd1: sys_value = group_id_x;
        8'd2: sys_value = group_id_y;
        8'd3: sys_value = NUM_WAVES;
        8'd4: sys_value = WAVE_WIDTH;
        8'd5: sys_value = LDS_SIZE;
        8'd8: sys_value = perf_cycles;
        8'd9: sys_value = perf_instrs;
        // perf_mma_busy and perf_lds_cycles read zero because neither unit
        // exists yet.  perf_gmem_bytes is real: s_ld_g moves four bytes.
        8'd10: sys_value = 32'b0;
        8'd11: sys_value = perf_gmem_bytes;
        8'd12: sys_value = 32'b0;
        default: sys_value = 32'b0;
    endcase
end

// ---------------------------------------------------------------- execute

always @(posedge clk or posedge reset) begin
    if (reset) begin
        PC <= 16'b0;
        bubble <= 2'b0;
        halted_r <= 1'b0;
        // Section 1.2 and 4.12: every lane is enabled at wave launch.
        exec <= 16'hffff;
        gmem_address <= 24'b0;
        gmem_dst <= 4'b0;
        gmem_read <= 1'b0;
        perf_cycles <= 32'b0;
        perf_instrs <= 32'b0;
        perf_gmem_bytes <= 32'b0;
        // Section 4.12: s0 is the kernel argument pointer, s1 and s2 are the
        // workgroup indices and "every other register is undefined".  Zero is
        // a legal choice for undefined and a far easier one to test against.
        for (i = 0; i < 16; i = i + 1) begin
            registers[i] <= 32'b0;
        end
        registers[0] <= kernel_arg_ptr;
        registers[1] <= group_id_x;
        registers[2] <= group_id_y;
    end
    else begin
        if (~halted_r) begin
            perf_cycles <= perf_cycles + 1;
        end

        if (bubble != 2'b0) begin
            bubble <= bubble - 2'b1;
        end

        gmem_read <= 1'b0;
        if (gmem_read) begin
            registers[gmem_dst] <= gmem_out;
        end

        if (issue) begin
            PC <= PC_next;
            perf_instrs <= perf_instrs + 1;

            case (opcode)
                // ------------------------------------------ 4.3 scalar ALU
                8'h00: registers[arg0] <= src0_value & src1_value;
                8'h01: registers[arg0] <= src0_value | src1_value;
                8'h02: registers[arg0] <= ~src0_value;
                8'h03: registers[arg0] <= src0_value ^ src1_value;
                8'h04: registers[arg0] <= src0_value + src1_value;
                8'h06: registers[arg0] <= src0_value - src1_value;
                8'h08: registers[arg0] <= -src0_value;
                8'h09: registers[arg0] <= src0_value * src1_value;
                8'h0b: registers[arg0] <= src0_value;
                8'h0c: registers[arg0] <= imm;
                8'h0d: registers[arg0] <= src0_value | imm;
                8'h0e: registers[arg0] <= src0_value << mod;
                8'h0f: registers[arg0] <= src0_value >> mod;
                8'h12: registers[arg0] <= $signed(src0_value) >>> mod;
                8'h13: registers[arg0] <= {16'b0, PC_next} + imm;
                8'h14: registers[arg0] <= src0_value << src1_value;
                8'h15: registers[arg0] <= src0_value >> src1_value;
                8'h16: registers[arg0] <= $signed(src0_value) >>> src1_value;
                8'h17: registers[arg0] <= ($signed(src0_value) < $signed(src1_value))
                                          ? src0_value : src1_value;
                8'h18: registers[arg0] <= ($signed(src0_value) > $signed(src1_value))
                                          ? src0_value : src1_value;
                8'h19: registers[arg0] <= {imm16, dst_value[15:0]};
                8'h1a: registers[arg0] <= src0_value + imm;
                8'h1b: registers[arg0] <= src0_value * imm;
                8'h1c: registers[arg0] <= src0_value & imm;
                8'h1d: registers[arg0] <= src0_value ^ imm;
                8'h1e: registers[arg0] <= sys_value;

                // ------------------------------- 4.4 scalar control flow
                //
                // cpu16's branch block, verbatim, at cpu16's own numbers.
                8'h20:
                    if (src0_value != 0) begin
                        PC <= src1_value[15:0];
                        bubble <= 2'd3;
                    end
                8'h21:
                    if (src0_value == 0) begin
                        PC <= src1_value[15:0];
                        bubble <= 2'd3;
                    end
                8'h22:
                    begin
                        PC <= src1_value[15:0];
                        bubble <= 2'd3;
                    end
                8'h23:
                    if ($signed(src0_value) < 0) begin
                        PC <= src1_value[15:0];
                        bubble <= 2'd3;
                    end
                8'h24:
                    if ($signed(src0_value) > 0) begin
                        PC <= src1_value[15:0];
                        bubble <= 2'd3;
                    end
                8'h25:
                    if (src0_value != 0) begin
                        PC <= PC_next + imm16;
                        bubble <= 2'd3;
                    end
                8'h26:
                    if (src0_value == 0) begin
                        PC <= PC_next + imm16;
                        bubble <= 2'd3;
                    end
                8'h27:
                    begin
                        PC <= PC_next + imm16;
                        bubble <= 2'd3;
                    end
                8'h28:
                    begin
                        registers[arg0] <= {16'b0, PC_next};
                        PC <= PC_next + imm16;
                        bubble <= 2'd3;
                    end
                // The two exec-mask branches.  Section 1.3 makes these the
                // escape hatch for a branch every lane has fallen out of: the
                // body is still correct with exec == 0 - every vector
                // instruction in it is a no-op - so these are an optimisation
                // and not a correctness requirement.
                8'h29:
                    if (exec == 16'b0) begin
                        PC <= PC_next + imm16;
                        bubble <= 2'd3;
                    end
                8'h2a:
                    if (exec != 16'b0) begin
                        PC <= PC_next + imm16;
                        bubble <= 2'd3;
                    end

                // --------------------------------------- 4.5 exec mask
                //
                // The saveexec family reads exec and writes it in the same
                // instruction, and the value saved is the value *before* the
                // update, so a program can restore it to reconverge.  Both
                // assignments are non blocking and both right hand sides
                // therefore see the old exec, including when Arg0 and Arg1
                // name the same register.
                8'h30: registers[arg0] <= {16'b0, exec};
                8'h31: exec <= src0_value[15:0];
                8'h32: begin
                    registers[arg0] <= {16'b0, exec};
                    exec <= exec & src0_value[15:0];
                end
                8'h33: begin
                    registers[arg0] <= {16'b0, exec};
                    exec <= exec | src0_value[15:0];
                end
                8'h34: begin
                    registers[arg0] <= {16'b0, exec};
                    exec <= exec ^ src0_value[15:0];
                end
                8'h35: exec <= 16'hffff;

                // ---------------------------------------- 4.6 vector ALU
                //
                // The VGPR writes all happen in the vector unit, which sees
                // this same instruction word and this same issue signal.  The
                // arms here are the two vector instructions whose destination
                // is a *scalar* register, plus one silent arm for the rest so
                // that they are not reported as unknown opcodes.
                8'h59: registers[arg0] <= readlane_value;
                8'h5c, 8'h5d, 8'h5e, 8'h5f:
                    registers[arg0] <= {16'b0, cmp_mask};
                8'h40, 8'h41, 8'h42, 8'h43, 8'h44, 8'h45, 8'h46, 8'h47,
                8'h48, 8'h49, 8'h4a, 8'h4b, 8'h4c, 8'h4d, 8'h4e, 8'h4f,
                8'h50, 8'h51, 8'h52, 8'h53, 8'h54, 8'h55, 8'h56, 8'h57,
                8'h58, 8'h5a, 8'h5b: ;

                // --------------------------------------- 4.8 global memory
                8'h85:
                begin
                    gmem_address <= gmem_effective;
                    gmem_dst <= arg0;
                    gmem_read <= 1'b1;
                    perf_gmem_bytes <= perf_gmem_bytes + 4;
                end

                // ------------------------------------ 4.10 wave control
                // s_waitcnt_g: every global load this implementation issues
                // has already completed, so there is never anything to wait
                // for.  The instruction still has to exist, because a correct
                // program is required to contain it.
                8'hb1: ;
                8'hb3: halted_r <= 1'b1;
                8'hbf: ;

                default: $display("unknown opcode %h", opcode);
            endcase
        end
    end
end

endmodule
