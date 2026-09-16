`include "memory.v"

// The 16 bit instruction / 8 bit data CPU.
//
// This module is written so that a synthesis tool will accept it.  That means
// three rules, all of which it used to break:
//
//   * no `#` delays anywhere - the old code used `#1` inside
//     `always @(posedge clk)` to let the memories settle, which is a
//     simulation trick with no hardware meaning;
//   * every piece of sequential state is written with a non blocking
//     assignment, and only from this one clocked block;
//   * there is no `initial` block zeroing the register file.  `reset` does
//     that, asynchronously, the way real silicon does.
//
// The behaviour is unchanged, cycle for cycle.  The two places where that
// needed care are both explicit now instead of being implied by statement
// order:
//
//   * a load writes its register on the same edge on which the next
//     instruction reads it.  With blocking assignments that fell out of the
//     write happening earlier in the block; now it is a forwarding mux
//     (`src0_value`, `src1_value`, `dst_value`) on the read side, plus a non
//     blocking write that the ALU's own write overrides if they collide.
//   * `stall` used to clear itself with a blocking assignment and then be
//     tested again in the same evaluation.  `stall_active` is that already
//     cleared value.
//
// THE LOADER.  A device has to get a program into the instruction memory
// somehow, and a hierarchical `$readmemh` from a testbench is not something
// that survives synthesis: on hardware the array would be written by nothing
// and initialised by nothing.  So the two memories have a real load port -
// one word or one byte per cycle, addressed from outside - and the testbench
// drives it exactly as a JTAG or UART loader would.  The path the board will
// use is therefore the path the tests exercise.
//
// The loader is expected to be used with `reset` held high, which is what
// makes it free: the CPU drives neither memory while it is in reset, so the
// loader simply takes the port, and no arbitration is needed.
module cpu_inst16_data8(
    input clk,
    input reset,

    // Instruction memory loader: one 16 bit word per cycle.
    input prog_load_enable,
    input [7:0] prog_load_address,
    input [15:0] prog_load_data,

    // Data memory loader: one byte per cycle.
    input data_load_enable,
    input [7:0] data_load_address,
    input [7:0] data_load_data
);

parameter INST_WIDTH = 16;

reg [7:0] IP; // Because program memory has latency,
              // IP point to next instruction address.
reg stall;
reg [7:0] stall_counter; // If it needs more than 1 stall clock

// `stall` is cleared by the same edge that would have been stalled, so the
// value the rest of the cycle sees is this one, not the register.  Nothing
// ever loads stall_counter with a non zero value today, so this is always 0;
// it is kept because the multi cycle stall it was written for is still the
// intended mechanism.
wire stall_active = stall & (stall_counter != 0);

integer i;

wire program_read_enable;
wire [7:0] program_address;
wire [INST_WIDTH-1:0] program_out_data;

// The second program memory port, which is what ld_p and st_p run on.  The
// fetch owns port A and never gives it up, so a program can read or write its
// own instruction memory without ever stalling the fetch.
wire program_b_enable;
reg program_b_write_enable;
reg program_b_read_enable;
reg program_b_half;
reg [7:0] program_b_address;
reg [7:0] program_b_in_data;
wire [7:0] program_b_out_data;
reg [2:0] program_b_dst;

program_memory program(
    .clk(clk),
    .a_enable(program_read_enable),
    .a_address(program_address),
    .a_out_data(program_out_data),
    .b_enable(program_b_enable),
    .b_write_enable(program_b_write_enable),
    .b_half(program_b_half),
    .b_address(program_b_address),
    .b_in_data(program_b_in_data),
    .b_out_data(program_b_out_data),
    .load_enable(prog_load_enable),
    .load_address(prog_load_address),
    .load_data(prog_load_data)
);

assign program_b_enable = 1'b1;

wire data_enable;
reg data_write_enable;
reg data_read_enable;
reg [7:0] data_address;
reg [7:0] data_in_data;
wire [7:0] data_out_data;
// The loader's mux in front of the data memory's one port.  Same argument as
// the instruction memory's: the CPU is in reset while the host loads, so this
// is a multiplexer rather than a second port.
wire data_mem_write_enable = data_load_enable | data_write_enable;
wire [7:0] data_mem_address = data_load_enable ? data_load_address : data_address;
wire [7:0] data_mem_in_data = data_load_enable ? data_load_data : data_in_data;

memory data(
    .clk(clk),
    .write_enable(data_mem_write_enable),
    .enable(data_enable),
    .address(data_mem_address),
    .in_data(data_mem_in_data),
    .out_data(data_out_data)
);

assign data_enable = 1'b1;

wire [INST_WIDTH-1:0] Inst;

assign program_address = IP;
assign program_read_enable = 1'b1;
assign Inst = stall_active ? {INST_WIDTH{1'b0}} : program_out_data;

reg [7:0] registers[7:0];

// Instruction layout:
//
//   |f e d c b a 9|8 7 6|5 4 3|2 1 0|
//   |   Opcode    | Arg0| Arg1| Arg2|
//
// For the data process instructions Arg0 is src0, Arg1 is src1 and Arg2 is dst.
// The immediate and shift instructions reinterpret Arg0/Arg1 as an immediate
// value and a shift amount; see README.md.
wire [6:0] opcode;
wire [2:0] src0;
wire [2:0] src1;
wire [2:0] dst;
wire [2:0] imm3;
wire [2:0] imm_shift;
wire [7:0] imm;
wire [2:0] shift_imm;

assign opcode = Inst[15:9];
assign src0 = Inst[8:6];
assign src1 = Inst[5:3];
assign dst = Inst[2:0];
assign imm3 = Inst[8:6];
assign imm_shift = Inst[5:3];
assign imm = {5'b0, imm3} << imm_shift;
assign shift_imm = Inst[5:3];

reg [2:0] data_dst;

// The write back of a load, which lands on this edge.  A memory read is
// issued in one cycle and its result is written on the next edge, at the same
// instant as the instruction that follows the load is decoded - so that
// instruction has to see the loaded value.  Only one of the two read enables
// can ever be set, because no single instruction sets both.
wire wb_valid = data_read_enable | program_b_read_enable;
wire [2:0] wb_index = program_b_read_enable ? program_b_dst : data_dst;
wire [7:0] wb_value = program_b_read_enable ? program_b_out_data : data_out_data;

wire [7:0] src0_value = (wb_valid && wb_index == src0) ? wb_value : registers[src0];
wire [7:0] src1_value = (wb_valid && wb_index == src1) ? wb_value : registers[src1];
wire [7:0] dst_value  = (wb_valid && wb_index == dst)  ? wb_value : registers[dst];

// The carry flag.  It is a single bit of processor state that lives outside
// the register file, written only by add, adc, sub and sbb, and read only by
// adc and sbb.  For add and adc it is the carry out of bit 7; for sub and sbb
// it is the borrow out of bit 7.  Nothing else disturbs it, so a multi byte
// add or subtract can be written as one add/sub followed by as many adc/sbb
// as it needs.
reg carry;

// 9 bits wide: [7:0] is the result, [8] is the carry or the borrow out.
wire [8:0] alu_add = src0_value + src1_value;
wire [8:0] alu_adc = src0_value + src1_value + carry;
wire [8:0] alu_sub = src0_value - src1_value;
wire [8:0] alu_sbb = src0_value - src1_value - carry;

// The instruction after this one, which is what `addpc` adds to.
wire [7:0] IP_next = stall_active ? IP : IP + 8'b1;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        IP <= 8'b0;
        stall <= 1'b0;
        stall_counter <= 8'b0;
        carry <= 1'b0;
        data_write_enable <= 1'b0;
        data_read_enable <= 1'b0;
        data_address <= 8'b0;
        data_in_data <= 8'b0;
        data_dst <= 3'b0;
        program_b_write_enable <= 1'b0;
        program_b_read_enable <= 1'b0;
        program_b_half <= 1'b0;
        program_b_address <= 8'b0;
        program_b_in_data <= 8'b0;
        program_b_dst <= 3'b0;
        for (i = 0; i < 8; i = i + 1) begin
            registers[i] <= 8'b0;
        end
    end
    else begin
        // A memory operation lasts exactly one edge, so every enable falls
        // again unless this cycle's instruction raises it below.
        data_write_enable <= 1'b0;
        data_read_enable <= 1'b0;
        program_b_write_enable <= 1'b0;
        program_b_read_enable <= 1'b0;

        // The load write back.  If the instruction below writes the same
        // register its assignment comes later and therefore wins, which is
        // what the blocking/non blocking pair used to arrange.
        if (wb_valid) begin
            registers[wb_index] <= wb_value;
        end

        if (stall) begin
            if (stall_counter == 0) begin
                stall <= 1'b0;
            end
            else begin
                stall_counter <= stall_counter - 1;
            end
        end

        IP <= IP_next;

        case (opcode)
            0: registers[dst] <= src0_value & src1_value;
            1: registers[dst] <= src0_value | src1_value;
            2: registers[dst] <= ~src0_value;
            3: registers[dst] <= src0_value ^ src1_value;
            4:
            begin
                registers[dst] <= alu_add[7:0];
                carry <= alu_add[8];
            end
            5:
            begin
                registers[dst] <= alu_adc[7:0];
                carry <= alu_adc[8];
            end
            6:
            begin
                registers[dst] <= alu_sub[7:0];
                carry <= alu_sub[8];
            end
            7:
            begin
                registers[dst] <= alu_sbb[7:0];
                carry <= alu_sbb[8];
            end
            8: registers[dst] <= -src0_value;
            9: registers[dst] <= src0_value * src1_value;
            10: registers[dst] <= src0_value / src1_value;
            11: registers[dst] <= src0_value;
            12: registers[dst] <= imm;
            13: registers[dst] <= dst_value | imm;
            14: registers[dst] <= src0_value << shift_imm;
            15: registers[dst] <= src0_value >> shift_imm;
            16: registers[dst] <= (src0_value << shift_imm)
                                | (src0_value >> (8 - shift_imm));
            17: registers[dst] <= (src0_value >> shift_imm)
                                | (src0_value << (8 - shift_imm));
            18: registers[dst] <= $signed(src0_value) >>> shift_imm;
            19: registers[dst] <= IP_next + imm;

            32:
                if (src0_value != 0) begin
                    IP <= src1_value;
                    stall <= 1'b1;
                end
            33:
                if (src0_value == 0) begin
                    IP <= src1_value;
                    stall <= 1'b1;
                end
            34:
                begin
                IP <= src1_value;
                stall <= 1'b1;
                end
            35:
                if ($signed(src0_value) < 0) begin
                    IP <= src1_value;
                    stall <= 1'b1;
                end
            36:
                if ($signed(src0_value) > 0) begin
                    IP <= src1_value;
                    stall <= 1'b1;
                end

            64:
            begin
                data_address <= src1_value;
                data_dst <= dst;
                data_read_enable <= 1'b1;
            end
            65:
            begin
                data_address <= src1_value;
                data_dst <= dst;
                data_write_enable <= 1'b1;
                data_in_data <= src0_value;
            end
            66:
            begin
                data_address <= src1_value;
                data_dst <= dst;
                data_write_enable <= 1'b1;
                data_in_data <= 8'b00000000;
            end
            67:
            begin
                data_address <= src1_value;
                data_dst <= dst;
                data_write_enable <= 1'b1;
                data_read_enable <= 1'b1;
                data_in_data <= dst_value;
            end
            68:
            begin
                program_b_address <= src1_value;
                program_b_half <= src0[0];
                program_b_dst <= dst;
                program_b_read_enable <= 1'b1;
            end
            69:
            begin
                program_b_address <= src1_value;
                program_b_half <= dst[0];
                program_b_in_data <= src0_value;
                program_b_write_enable <= 1'b1;
            end
            default: $display("unknown opcode %b", opcode);
        endcase
    end
end

endmodule
