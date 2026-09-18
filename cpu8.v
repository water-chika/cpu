`include "memory.v"

// The 8 bit instruction / 8 bit data CPU.
//
// Rewritten in the same synthesisable style as cpu16.v: no `#` delays, every
// piece of sequential state written with a non blocking assignment from one
// clocked block, and an asynchronous `reset` in place of the `initial` blocks
// that used to set the register file, the instruction pointer and the
// condition flag.  Behaviour is unchanged cycle for cycle; see the comment at
// the top of cpu16.v for the two places where preserving that needed an
// explicit mux.
//
// THE LOADER.  See the comment on cpu16.v's: `program_write_enable` used to be
// tied to zero, so on a device nothing could ever write the instruction memory
// and nothing ever filled it - a synthesis tool would have been entitled to
// replace the whole array with a constant.  Both memories now have a real load
// port, driven from outside one word per cycle while `reset` is held high, and
// the testbench loads through it instead of reaching into the hierarchy.
//
// THE SECOND PROGRAM MEMORY PORT.  `ld_p` and `st_p` (opcodes 28 and 29) used
// to fall through to `unknown opcode`, because the instruction memory had one
// port and the fetch owned it.  It is a `program_memory8` now - fetch on port
// A, ld_p and st_p on port B, the loader muxed in front of B - which is
// exactly the arrangement cpu16.v has, minus the half-word select that an
// 8 bit program word does not need.
module cpu_inst8_data8(
    input clk,
    input reset,

    // Instruction memory loader: one 8 bit word per cycle.
    input prog_load_enable,
    input [7:0] prog_load_address,
    input [7:0] prog_load_data,

    // Data memory loader: one byte per cycle.
    input data_load_enable,
    input [7:0] data_load_address,
    input [7:0] data_load_data
);

parameter INST_WIDTH = 8;

reg [7:0] IP; // Because program memory has latency,
              // IP point to next instruction address.
reg [7:0] instruction_pointer_1;
reg stall;
reg [7:0] stall_counter; // If it needs more than 1 stall clock

// See cpu16.v: this is `stall` after the clear that used to happen with a
// blocking assignment part way through the cycle.
wire stall_active = stall & (stall_counter != 0);

integer i;

wire program_read_enable;
wire [7:0] program_address;
wire [INST_WIDTH-1:0] program_out_data;

// The second program memory port, which is what ld_p and st_p run on.  The
// fetch owns port A and never gives it up, so a program can read or write its
// own instruction memory without ever stalling the fetch.  cpu16 has to say
// which half of its 16 bit program word it means; here a program word is 8
// bits, which is exactly one register, so the address is the whole operand.
wire program_b_enable;
reg program_b_write_enable;
reg program_b_read_enable;
reg [7:0] program_b_address;
reg [7:0] program_b_in_data;
wire [7:0] program_b_out_data;
reg [2:0] program_b_dst;

program_memory8 program(
    .clk(clk),
    .a_enable(program_read_enable),
    .a_address(program_address),
    .a_out_data(program_out_data),
    .b_enable(program_b_enable),
    .b_write_enable(program_b_write_enable),
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
// The loader's mux in front of the data memory's one port.  The CPU is in
// reset while the host loads, so this is a multiplexer and not a second port.
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

// The fetch owns port A of the instruction memory and never gives it up: the
// loader has its own port now, and the CPU is held in reset while it is used.
assign program_address = IP;
assign program_read_enable = 1'b1;
assign Inst = stall_active ? 8'b00000000 : program_out_data;

reg [7:0] registers[7:0];
reg [0:0] condition;

wire [4:0] opcode;
wire [2:0] arg;
wire [2:0] src0;
reg [2:0] src1;
wire [2:0] dst;
wire [2:0] dst1;
wire [7:0] imm;
wire [2:0] shift_imm;
assign opcode = Inst[7:3];
assign src0 = Inst[2:0];
assign dst = src0;
assign dst1 = src1;
assign imm = Inst[2:0];
assign shift_imm = Inst[2:0];
assign arg = Inst[2:0];

reg [2:0] data_dst;

// The write back of a load, which lands on the same edge as the decode of the
// instruction that follows the load, so that instruction has to see it.  A
// load from data memory and a load from program memory share this path,
// because no single instruction issues both.
wire wb_valid = data_read_enable | program_b_read_enable;
wire [2:0] wb_index = program_b_read_enable ? program_b_dst : data_dst;
wire [7:0] wb_value = program_b_read_enable ? program_b_out_data : data_out_data;

wire [7:0] src0_value = (wb_valid && wb_index == src0) ? wb_value
                                                      : registers[src0];
wire [7:0] src1_value = (wb_valid && wb_index == src1) ? wb_value
                                                      : registers[src1];

// The instruction after this one.
wire [7:0] IP_next = stall_active ? IP : IP + 8'b1;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        IP <= 8'b0;
        instruction_pointer_1 <= 8'b0;
        stall <= 1'b0;
        stall_counter <= 8'b0;
        condition <= 1'b1;
        src1 <= 3'b0;
        data_write_enable <= 1'b0;
        data_read_enable <= 1'b0;
        data_address <= 8'b0;
        data_in_data <= 8'b0;
        data_dst <= 3'b0;
        program_b_write_enable <= 1'b0;
        program_b_read_enable <= 1'b0;
        program_b_address <= 8'b0;
        program_b_in_data <= 8'b0;
        program_b_dst <= 3'b0;
        for (i = 0; i < 8; i = i + 1) begin
            registers[i] <= 8'b0;
        end
    end
    else begin
        // A memory operation lasts exactly one edge.
        data_write_enable <= 1'b0;
        data_read_enable <= 1'b0;
        program_b_write_enable <= 1'b0;
        program_b_read_enable <= 1'b0;

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

        if (condition) begin
        case (opcode)
            0: registers[dst]     <= src0_value    & src1_value;
            1: registers[dst]     <= src0_value    | src1_value;
            2: registers[dst]     <= 8'b11111111   ^ src1_value;
            3: registers[dst]     <= src0_value    ^ src1_value;
            4: registers[dst]     <= src0_value    + src1_value;
            5: registers[dst]     <= src0_value    - src1_value;
            6: registers[dst]     <= 8'b00000000   - src1_value;
            7: registers[dst]     <= src0_value    * src1_value;
            8: registers[dst]     <= src0_value    / src1_value;
            9: registers[dst]     <= 8'b00000000   | src1_value;
            10: registers[dst1]   <= src0_value    | 8'b00000000;
            11: registers[dst1]   <=           imm;
            12: registers[dst1]   <= src1_value   << shift_imm;
            13: registers[dst1]   <= src1_value   >> shift_imm;

            14: condition <= src0_value != 0;
            15: condition <= src0_value == 0;
            16: condition <= src0_value < 0;
            17: condition <= src0_value > 0;
            18:
                begin
                    case (arg)
                        0: condition <= 1;
                        1:
                            begin
                                IP <= instruction_pointer_1;
                                stall <= 1'b1;
                            end
                        default: ;
                    endcase
                end

            19: instruction_pointer_1 <= src0_value;
            20: data_address <= src0_value;

            24:
            begin
                data_dst <= dst;
                data_read_enable <= 1'b1;
            end
            25:
            begin
                data_write_enable <= 1'b1;
                data_in_data <= src0_value;
            end
            26:
            begin
                data_write_enable <= 1'b1;
                data_in_data <= 8'b00000000;
            end
            27:
            begin
                data_dst <= dst;
                data_write_enable <= 1'b1;
                data_read_enable <= 1'b1;
                data_in_data <= src0_value;
            end

            // ld_p and st_p, the two instructions that reach the instruction
            // memory.  They take the address from the same register that
            // set_data_address loads, because there is one address register
            // and the opcode says which memory it applies to.
            28:
            begin
                program_b_address <= data_address;
                program_b_dst <= dst;
                program_b_read_enable <= 1'b1;
            end
            29:
            begin
                program_b_address <= data_address;
                program_b_in_data <= src0_value;
                program_b_write_enable <= 1'b1;
            end

            31: src1 <= arg;
            default: $display("unknown opcode %b", opcode);
        endcase
        end
        // "endif": an opcode 18 always re-enables execution, even the one
        // that was itself skipped.  This comes last so that it overrides the
        // arms above.
        if (opcode == 18) condition <= 1;
    end
end

endmodule
