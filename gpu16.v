`include "memory.v"
`include "gpu16_gmem.v"
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
// The vector unit is instantiated below the memory unit, because the memory
// unit is what drives half its ports.
wire [511:0] vaddr;
wire [511:0] vec_st_data;

// The instruction after this one.  Section 4.3 and 4.4 define s_addpc,
// s_call and every `_i` branch against it, and the PC is word addressed.
wire [15:0] PC_next = PC + 16'b1;

// ---------------------------------------------------------------- memory unit
//
// Sections 3.1 and 4.8.  One unit serves every memory instruction, scalar or
// per lane, because there is one global port and section 3.1 says how wide it
// is: **64 B per cycle, aligned**, one transaction per distinct aligned 64
// byte block.  That rule is implemented here literally, and it is the only
// thing in this file that takes more than one cycle for reasons that are not
// a branch:
//
//   * an access latches its sixteen lane addresses and the exec mask,
//   * then spends one cycle per *distinct* block over the enabled lanes,
//     marking off every lane that block serves,
//   * and moves one VGPR per cycle at the register file end, which is one
//     cycle for a 1 or 4 byte access and four for a 16 byte one - section
//     4.8's "the return path writes one VGPR per cycle ... over four
//     consecutive cycles", and the mirror of it for a store.
//
// So sixteen lanes reading four consecutive bytes each from a 64 byte aligned
// base is one transaction and sixteen lanes walking a matrix column is
// sixteen, exactly as section 3.1 promises, and the difference is visible in
// `perf_cycles` and counted exactly by `perf_gmem_trans` (system register 13,
// section 4.3).
//
// Every lane access lies inside one block by construction and never straddles
// two: a 4 byte access is truncated to a multiple of 4 and a 16 byte one to a
// multiple of 16, both of which divide 64.  A transaction therefore serves a
// lane completely or not at all, which is what makes "one cycle per distinct
// block" the whole cost model.
//
// The wave stalls for those cycles rather than running on.  Section 1.4 wants
// global accesses to be fire-and-forget with `s_waitcnt_g` as the only thing
// that makes a result visible, and this implementation is the degenerate case
// of that: the access has always completed by the time the next instruction
// issues, so `s_waitcnt_g` has nothing to wait for and is a no-op.  A correct
// program still has to contain it, and there is deliberately no forwarding
// path, so a program that omits it does not accidentally work here and then
// fail against a machine with a real outstanding-operation queue.
//
// `s_ld_g` keeps its own two cycle path - latch the address, select its word
// out of the block the next cycle - and cannot collide with the per lane unit
// for the port: only one instruction issues per cycle, so a `s_ld_g` issued
// in cycle A reads in cycle A+1, while a per lane access issued no earlier
// than A+1 takes its first transaction no earlier than A+2.

localparam MEM_IDLE    = 3'd0;
localparam MEM_GATHER  = 3'd1;   // load:  one cycle per distinct block
localparam MEM_RETURN  = 3'd2;   // load:  one VGPR per cycle back to the file
localparam MEM_READ    = 3'd3;   // store: one VGPR per cycle out of the file
localparam MEM_SCATTER = 3'd4;   // store: one cycle per distinct block

reg [2:0] mem_state;
reg [7:0] mem_op;
reg [3:0] mem_reg;
reg [1:0] mem_j;
reg [15:0] mem_exec;
// Lanes this access has finished with.  Disabled lanes start finished, which
// is section 1.2's "memory instructions issue a transaction only for enabled
// lanes" with no second rule needed anywhere below.
reg [15:0] served;
reg [383:0] lane_addr;    // sixteen 24 bit effective addresses
reg [2047:0] stage;       // sixteen lanes x four words, the unit's own buffer
reg [3:0] st_reg;

// A wave issues nothing while the memory unit is still working through an
// access, which is the second of the two reasons this machine stalls - the
// first being a taken branch's bubble.
wire issue = (bubble == 2'b0) & ~halted_r & (mem_state == MEM_IDLE);

wire mem_quad = (mem_op == 8'h86) | (mem_op == 8'h87);
wire mem_word = (mem_op == 8'h82) | (mem_op == 8'h84);
wire mem_sext = (mem_op == 8'h81);

// The same three facts about the instruction being issued this cycle.
wire op_store = (opcode == 8'h83) | (opcode == 8'h84) | (opcode == 8'h87);
wire op_quad = (opcode == 8'h86) | (opcode == 8'h87);
wire op_word = (opcode == 8'h82) | (opcode == 8'h84);
wire [5:0] op_bytes = op_quad ? 6'd16 : op_word ? 6'd4 : 6'd1;
// Section 4.8: the address is truncated *down* to a multiple of the access
// width, rather than faulting or rotating.
wire [23:0] op_addr_mask = op_quad ? 24'hfffff0
                         : op_word ? 24'hfffffc
                                   : 24'hffffff;

// ---- the transaction the unit would issue this cycle
//
// The lowest numbered unfinished lane names the block; every unfinished lane
// in that block rides along.  Picking the lowest is arbitrary - section 3.1
// fixes how many transactions there are and says nothing about their order -
// but it is deterministic, which a test can be written against.

wire [15:0] unserved = ~served;

integer k;
integer l;
integer j;

reg [3:0] first_lane;
reg any_unserved;
always @* begin
    first_lane = 4'b0;
    any_unserved = 1'b0;
    for (k = 0; k < 16; k = k + 1) begin
        if (!any_unserved && unserved[k]) begin
            any_unserved = 1'b1;
            first_lane = k[3:0];
        end
    end
end

wire [17:0] cur_block = lane_addr[24*first_lane+6+:18];

reg [15:0] match;
always @* begin
    for (k = 0; k < 16; k = k + 1) begin
        match[k] = unserved[k] & (lane_addr[24*k+6+:18] == cur_block);
    end
end

// ---- the port itself

reg [5:0] gather_off;
reg [7:0] gather_byte;
reg [5:0] soff;
reg [511:0] gmem_wdata;
reg [63:0] gmem_be;
always @* begin
    gmem_wdata = 512'b0;
    gmem_be = 64'b0;
    soff = 6'b0;
    for (k = 0; k < 16; k = k + 1) begin
        if (match[k]) begin
            soff = lane_addr[24*k+:6];
            if (mem_quad) begin
                gmem_wdata[8*soff+:128] = stage[128*k+:128];
                gmem_be[soff+:16] = 16'hffff;
            end
            else if (mem_word) begin
                gmem_wdata[8*soff+:32] = stage[128*k+:32];
                gmem_be[soff+:4] = 4'hf;
            end
            else begin
                gmem_wdata[8*soff+:8] = stage[128*k+:8];
                gmem_be[soff+:1] = 1'b1;
            end
        end
    end
end

reg [23:0] gmem_address;
reg [3:0] gmem_dst;
reg gmem_read;
wire [511:0] gmem_out_block;

wire mem_active = (mem_state == MEM_GATHER) | (mem_state == MEM_SCATTER);
wire [17:0] port_block = mem_active ? cur_block : gmem_address[23:6];
wire port_write = (mem_state == MEM_SCATTER) & any_unserved;

gpu16_gmem #(
    .WORD_INDEX_WIDTH(DATA_INDEX_WIDTH)
) data (
    .clk(clk),
    // The data address is a 24 bit *byte* address and a block is 64 bytes,
    // so the block index drops the low six.  This instance implements only
    // the low DATA_INDEX_WIDTH words of that space.
    .block_index(port_block[DATA_INDEX_WIDTH-5:0]),
    .write_enable(port_write),
    .byte_enable(gmem_be),
    .in_block(gmem_wdata),
    .out_block(gmem_out_block)
);

// `s_ld_g`'s word, selected out of the block its address lands in.
wire [31:0] gmem_word = gmem_out_block[32*gmem_address[5:2]+:32];

wire [23:0] gmem_effective = src1_value[23:0] + {16'b0, mod};

// ---- the load return path, one VGPR per cycle

reg [511:0] mem_wb_data;
always @* begin
    for (k = 0; k < 16; k = k + 1) begin
        mem_wb_data[32*k+:32] = stage[128*k+32*mem_j+:32];
    end
end

wire mem_write = (mem_state == MEM_RETURN);
wire [3:0] mem_wb_reg = mem_reg + {2'b0, mem_j};

// How many lanes an access actually moves data for, for perf_gmem_bytes.
reg [5:0] exec_count;
always @* begin
    exec_count = 6'b0;
    for (k = 0; k < 16; k = k + 1) begin
        exec_count = exec_count + {5'b0, exec[k]};
    end
end
wire [31:0] op_bytes_moved = {26'b0, exec_count} * {26'b0, op_bytes};

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
    .readlane_value(readlane_value),
    .vaddr(vaddr),
    .st_reg(st_reg),
    .st_data(vec_st_data),
    .mem_write(mem_write),
    .mem_reg(mem_wb_reg),
    .mem_mask(mem_exec),
    .mem_data(mem_wb_data)
);

// ---------------------------------------------------------------- system registers

reg [31:0] perf_cycles;
reg [31:0] perf_instrs;
reg [31:0] perf_gmem_bytes;
reg [31:0] perf_gmem_trans;

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
        // exists yet.  perf_gmem_bytes is real: it counts the bytes the
        // program asked for, which is section 7.2's "Bytes" metric - four for
        // an s_ld_g, and the access width times the number of enabled lanes
        // for a per lane access.
        8'd10: sys_value = 32'b0;
        8'd11: sys_value = perf_gmem_bytes;
        8'd12: sys_value = 32'b0;
        // Section 4.3, system register 13: global transactions issued, in
        // section 3.1's sense of the word - one per distinct aligned 64 byte
        // block per access.  Section 3.1 is the rule the whole memory system
        // is built on and section 7.4 proposes falsifying tier-1 predictions
        // against the RTL, but the counters 8-12 can only see the *bytes* a
        // kernel asked for, never how many port cycles it cost to move them.
        // Those are different numbers whenever an access is not perfectly
        // coalesced - section 3.1's own worked example is a fill that runs at
        // 50% transaction efficiency - so the transaction count is its own
        // counter rather than something a test has to infer from cycles.
        8'd13: sys_value = perf_gmem_trans;
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
        perf_gmem_trans <= 32'b0;
        mem_state <= MEM_IDLE;
        mem_op <= 8'b0;
        mem_reg <= 4'b0;
        mem_j <= 2'b0;
        mem_exec <= 16'b0;
        served <= 16'hffff;
        lane_addr <= 384'b0;
        stage <= 2048'b0;
        st_reg <= 4'b0;
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
            registers[gmem_dst] <= gmem_word;
        end

        // ---- the per lane memory unit, one state per phase of an access
        case (mem_state)
            MEM_GATHER: begin
                if (any_unserved) begin
                    for (l = 0; l < 16; l = l + 1) begin
                        if (match[l]) begin
                            gather_off = lane_addr[24*l+:6];
                            if (mem_quad) begin
                                for (j = 0; j < 4; j = j + 1) begin
                                    stage[128*l+32*j+:32] <=
                                        gmem_out_block[8*gather_off+32*j+:32];
                                end
                            end
                            else if (mem_word) begin
                                stage[128*l+:32] <= gmem_out_block[8*gather_off+:32];
                            end
                            else begin
                                // One byte, zero extended by v_ld_g and sign
                                // extended by v_ld_gs.
                                gather_byte = gmem_out_block[8*gather_off+:8];
                                stage[128*l+:32] <= mem_sext
                                    ? {{24{gather_byte[7]}}, gather_byte}
                                    : {24'b0, gather_byte};
                            end
                        end
                    end
                    served <= served | match;
                    perf_gmem_trans <= perf_gmem_trans + 1;
                    if ((served | match) == 16'hffff) begin
                        mem_state <= MEM_RETURN;
                        mem_j <= 2'b0;
                    end
                end
                else begin
                    // exec was zero: no lane reads, and the destination quad
                    // is left alone because MEM_RETURN's mask is mem_exec.
                    mem_state <= MEM_RETURN;
                    mem_j <= 2'b0;
                end
            end
            MEM_RETURN: begin
                // The write itself happens in the vector unit, off
                // mem_write / mem_wb_reg / mem_exec / mem_wb_data.
                if (mem_quad & (mem_j != 2'd3)) begin
                    mem_j <= mem_j + 2'b1;
                end
                else begin
                    mem_state <= MEM_IDLE;
                end
            end
            MEM_READ: begin
                for (l = 0; l < 16; l = l + 1) begin
                    stage[128*l+32*mem_j+:32] <= vec_st_data[32*l+:32];
                end
                st_reg <= st_reg + 4'b1;
                if (mem_quad & (mem_j != 2'd3)) begin
                    mem_j <= mem_j + 2'b1;
                end
                else begin
                    mem_state <= MEM_SCATTER;
                end
            end
            MEM_SCATTER: begin
                // The write to memory is the port_write / gmem_be / gmem_wdata
                // the block above drives; what is left is the bookkeeping.
                if (any_unserved) begin
                    served <= served | match;
                    perf_gmem_trans <= perf_gmem_trans + 1;
                    if ((served | match) == 16'hffff) begin
                        mem_state <= MEM_IDLE;
                    end
                end
                else begin
                    mem_state <= MEM_IDLE;
                end
            end
            default: ;
        endcase

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
                //
                // Every per lane access starts the same way: latch the
                // sixteen effective addresses `v[Arg1] + s[Arg2] + zext(Mod)`
                // truncated to the access width, latch the exec mask, and
                // hand the lot to the memory unit.  A load then gathers and
                // returns; a store reads its source registers and scatters.
                8'h80, 8'h81, 8'h82, 8'h83, 8'h84, 8'h86, 8'h87:
                begin
                    for (i = 0; i < 16; i = i + 1) begin
                        lane_addr[24*i+:24] <=
                            (vaddr[32*i+:24] + src1_value[23:0] + {16'b0, mod})
                            & op_addr_mask;
                    end
                    mem_op <= opcode;
                    mem_reg <= arg0;
                    mem_exec <= exec;
                    served <= ~exec;
                    mem_j <= 2'b0;
                    st_reg <= arg0;
                    mem_state <= op_store ? MEM_READ : MEM_GATHER;
                    perf_gmem_bytes <= perf_gmem_bytes + op_bytes_moved;
                end

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
