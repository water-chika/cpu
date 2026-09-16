`include "gpu16.v"
`include "gpu16_matrix.v"

// gpu16_cu: one compute unit - the workgroup of four waves that docs/
// gpu_isa.md describes, rather than the single wave gpu16.v is.
//
// Three things in the ISA only exist because a workgroup has more than one
// wave in it, and none of them can be implemented, let alone tested, one wave
// at a time:
//
//   * section 3.2's LDS is "shared by the 4 waves of a workgroup".  A private
//     scratchpad per wave would pass every value test ever written against a
//     single wave and be useless for the thing LDS is for, which is one wave
//     reading what another wave staged.
//   * section 3.3's `s_barrier` - "all waves of the workgroup wait until all
//     have arrived" - is a no-op when there is only ever one wave to wait
//     for, and a no-op cannot be tested.
//   * section 7.2's Model-A issues "one instruction per cycle per compute
//     unit, round-robin over ready waves", which is a statement about a
//     shared issue slot and not about a wave.
//
// So this module owns everything shared - the global port, the LDS, the
// issue slot, the barrier and the three workgroup performance counters - and
// the waves own only what is theirs: a PC, registers, an exec mask and a
// memory unit that asks for the ports rather than containing them.
//
// ARBITRATION.  Two rules, both deliberately boring, because the ISA fixes
// how many port cycles an access costs and says nothing about their order:
//
//   * the issue slot rotates, which is Model-A's "round-robin over ready
//     waves" exactly;
//   * each memory port goes to the lowest numbered wave asking for it.
//     Fixed priority cannot starve anyone here because no access is
//     unbounded: every request is for one of at most sixteen port cycles and
//     then stops.
//
// A wave whose request is not granted does not advance its memory unit that
// cycle.  That is the whole of the contention model, and it is why a
// workgroup's cycle count is not simply four times a wave's.
//
// The program memory stays inside each wave.  Four waves fetch every cycle,
// so a single shared instruction memory would need four read ports; giving
// each wave its own copy of the program is the honest simulation of a fetch
// path that never misses, and costs nothing that the ISA can observe.
module gpu16_cu #(
    parameter PROGRAM_ADDR_WIDTH = 12,
    parameter DATA_INDEX_WIDTH = 10
) (
    input clk,
    input reset,

    input [31:0] kernel_arg_ptr,
    input [31:0] group_id_x,
    input [31:0] group_id_y,
    // Wave *w* of the workgroup is launched with `wave_id_base + w`, so a
    // single wave configuration can still be given any wave id it likes.
    input [31:0] wave_id_base,
    // How many of the four wave slots this workgroup fills, 1 to 4.
    input [2:0] waves,

    // High once every launched wave has retired its s_endpgm.
    output halted,

    // The program memory loader, section 2.2(a) of docs/fpga_bringup.md.  One
    // instruction word per cycle, written into all four waves at once: every
    // wave of a workgroup runs the same program, so the four private copies
    // of the instruction memory are four copies of one thing and there is no
    // reason for the host to write them one at a time.
    input prog_load_enable,
    input [PROGRAM_ADDR_WIDTH-1:0] prog_load_address,
    input [31:0] prog_load_data
);

localparam WAVES = 4;

// Every combinational block below gets its own loop variable and its own
// flag.  Sharing one `integer k` between two `always @*` blocks makes each
// block sensitive to the other's writes to it, and the pair then retrigger
// one another forever at the same simulation time.

wire [3:0] launch;
assign launch[0] = (waves > 3'd0);
assign launch[1] = (waves > 3'd1);
assign launch[2] = (waves > 3'd2);
assign launch[3] = (waves > 3'd3);

wire [3:0] w_halted;
wire [3:0] w_issue_request;
wire [3:0] w_g_request;
wire [3:0] w_g_write;
wire [71:0] w_g_block;          // 4 x 18
wire [255:0] w_g_byte_enable;   // 4 x 64
wire [2047:0] w_g_wdata;        // 4 x 512
wire [3:0] w_l_request;
wire [63:0] w_l_bank_write;     // 4 x 16
wire [447:0] w_l_bank_row;      // 4 x 112
wire [255:0] w_l_byte_enable;   // 4 x 64
wire [2047:0] w_l_wdata;        // 4 x 512
wire [3:0] w_barrier_wait;
wire [127:0] w_bytes_add;       // 4 x 32
wire [3:0] w_m_request;
wire [127:0] w_m_a;             // 4 x 32
wire [2047:0] w_m_b;            // 4 x 512
wire [2047:0] w_m_acc;          // 4 x 512
wire [3:0] w_m_zero;

// ---------------------------------------------------------------- issue
//
// Model-A's round robin.  `rr` is the wave the sweep starts at, so a wave
// that issues moves to the back of the queue and a wave that is stalled -
// in a branch bubble, waiting on its memory unit or sitting on a barrier -
// is skipped rather than blocking the unit.

reg [1:0] rr;
reg [3:0] issue_grant;
reg [1:0] issue_pick;
integer ki;
reg [1:0] idx;
reg found_i;
always @* begin
    issue_grant = 4'b0;
    issue_pick = 2'b0;
    found_i = 1'b0;
    for (ki = 0; ki < WAVES; ki = ki + 1) begin
        idx = rr + ki[1:0];
        if (~found_i & w_issue_request[idx]) begin
            found_i = 1'b1;
            issue_pick = idx;
            issue_grant[idx] = 1'b1;
        end
    end
end

// ---------------------------------------------------------------- barrier
//
// Section 3.3.  A wave counts as arrived while it is sitting on an
// `s_barrier` it has not been let through, and a wave that has ended counts
// as arrived too - otherwise a workgroup whose waves do not all execute the
// same number of barriers would deadlock on the dead one, and section 3.3
// says the barrier waits for the waves of the workgroup, not for their
// ghosts.  The release is one cycle wide; each waiting wave latches it.

wire [3:0] arrived = w_barrier_wait | w_halted;
wire barrier_release = (&arrived) & (|w_barrier_wait);

// ---------------------------------------------------------------- the ports

reg [3:0] g_grant;
integer kg;
reg found_g;
always @* begin
    g_grant = 4'b0;
    found_g = 1'b0;
    for (kg = 0; kg < WAVES; kg = kg + 1) begin
        if (~found_g & w_g_request[kg]) begin
            found_g = 1'b1;
            g_grant[kg] = 1'b1;
        end
    end
end

reg [3:0] l_grant;
integer kl;
reg found_l;
always @* begin
    l_grant = 4'b0;
    found_l = 1'b0;
    for (kl = 0; kl < WAVES; kl = kl + 1) begin
        if (~found_l & w_l_request[kl]) begin
            found_l = 1'b1;
            l_grant[kl] = 1'b1;
        end
    end
end

reg [17:0] g_block;
reg g_write;
reg [63:0] g_byte_enable;
reg [511:0] g_wdata;
integer kgs;
always @* begin
    g_block = 18'b0;
    g_write = 1'b0;
    g_byte_enable = 64'b0;
    g_wdata = 512'b0;
    for (kgs = 0; kgs < WAVES; kgs = kgs + 1) begin
        if (g_grant[kgs]) begin
            g_block = w_g_block[18*kgs+:18];
            g_write = w_g_write[kgs];
            g_byte_enable = w_g_byte_enable[64*kgs+:64];
            g_wdata = w_g_wdata[512*kgs+:512];
        end
    end
end

reg [15:0] l_bank_write;
reg [111:0] l_bank_row;
reg [63:0] l_byte_enable;
reg [511:0] l_wdata;
integer kls;
always @* begin
    l_bank_write = 16'b0;
    l_bank_row = 112'b0;
    l_byte_enable = 64'b0;
    l_wdata = 512'b0;
    for (kls = 0; kls < WAVES; kls = kls + 1) begin
        if (l_grant[kls]) begin
            l_bank_write = w_l_bank_write[16*kls+:16];
            l_bank_row = w_l_bank_row[112*kls+:112];
            l_byte_enable = w_l_byte_enable[64*kls+:64];
            l_wdata = w_l_wdata[512*kls+:512];
        end
    end
end

wire [511:0] g_rdata;
wire [511:0] l_rdata;

// ------------------------------------------------- the shared matrix unit
//
// Section 4.7's 64 int8 MACs, one array for the workgroup.  Section 7.3
// prices a workgroup iteration at "1024 matrix cycles" for four waves of 16
// `mma_i8`, i.e. 4 x 256, which is the arithmetic of four waves sharing one
// array; four private arrays would have made it 256 and the matrix unit would
// not have been the limiter the whole section says it is.
//
// The grant rotates rather than going to the lowest numbered asker, which is
// the one place this module departs from the fixed priority the memory ports
// use, and for a reason the ports do not have: a memory access asks for at
// most sixteen cycles and then stops, while a wave in a GEMM inner loop can
// re-arm its request the cycle after it finishes one `mma_i8` and would hold
// a fixed priority arbiter indefinitely.  Round robin here is the same rule
// the issue slot already uses, and is what makes matrix utilisation a
// property of the workgroup rather than of wave 0.
reg [1:0] mrr;
reg [3:0] m_grant;
reg [1:0] m_pick;
integer km;
reg [1:0] midx;
reg found_m;
always @* begin
    m_grant = 4'b0;
    m_pick = 2'b0;
    found_m = 1'b0;
    for (km = 0; km < WAVES; km = km + 1) begin
        midx = mrr + km[1:0];
        if (~found_m & w_m_request[midx]) begin
            found_m = 1'b1;
            m_pick = midx;
            m_grant[midx] = 1'b1;
        end
    end
end

reg [31:0] m_a;
reg [511:0] m_b;
reg [511:0] m_acc;
reg m_zero;
integer kms;
always @* begin
    m_a = 32'b0;
    m_b = 512'b0;
    m_acc = 512'b0;
    m_zero = 1'b0;
    for (kms = 0; kms < WAVES; kms = kms + 1) begin
        if (m_grant[kms]) begin
            m_a = w_m_a[32*kms+:32];
            m_b = w_m_b[512*kms+:512];
            m_acc = w_m_acc[512*kms+:512];
            m_zero = w_m_zero[kms];
        end
    end
end

wire [511:0] m_result;

gpu16_matrix matrix (
    .a_frag(m_a),
    .b_frag(m_b),
    .acc_in(m_acc),
    .zero_acc(m_zero),
    .acc_out(m_result)
);

gpu16_gmem #(
    .WORD_INDEX_WIDTH(DATA_INDEX_WIDTH)
) data (
    .clk(clk),
    // The data address is a 24 bit *byte* address and a block is 64 bytes,
    // so the block index drops the low six.  This instance implements only
    // the low DATA_INDEX_WIDTH words of that space.
    .block_index(g_block[DATA_INDEX_WIDTH-5:0]),
    .write_enable(g_write),
    .byte_enable(g_byte_enable),
    .in_block(g_wdata),
    .out_block(g_rdata)
);

gpu16_lds lds (
    .clk(clk),
    .bank_row(l_bank_row),
    .bank_write(l_bank_write),
    .byte_enable(l_byte_enable),
    .in_data(l_wdata),
    .out_data(l_rdata)
);

// ------------------------------------------------- the workgroup counters
//
// Section 4.3 says "by this workgroup" for all three, which is why they are
// here and not in a wave: a wave can see the whole workgroup's traffic, and
// four waves reading system register 11 all read the same number.
//
// A transaction is a granted global port cycle and an LDS port cycle is a
// granted LDS one, which is the most direct statement of section 3.1's and
// section 3.2's rules there is - the counter cannot disagree with the port
// because it *is* the port.  Note this counts `s_ld_g`'s read as a
// transaction, which it is: it occupies the 64 byte port for a cycle like
// anything else.

reg [31:0] perf_gmem_bytes;
reg [31:0] perf_gmem_trans;
reg [31:0] perf_lds_cycles;
reg [31:0] perf_mma_busy;

reg [31:0] bytes_this_cycle;
integer kb;
always @* begin
    bytes_this_cycle = 32'b0;
    for (kb = 0; kb < WAVES; kb = kb + 1) begin
        bytes_this_cycle = bytes_this_cycle + w_bytes_add[32*kb+:32];
    end
end

always @(posedge clk or posedge reset) begin
    if (reset) begin
        rr <= 2'b0;
        mrr <= 2'b0;
        perf_gmem_bytes <= 32'b0;
        perf_gmem_trans <= 32'b0;
        perf_lds_cycles <= 32'b0;
        perf_mma_busy <= 32'b0;
    end
    else begin
        if (|issue_grant) begin
            rr <= issue_pick + 2'b1;
        end
        if (|m_grant) begin
            mrr <= m_pick + 2'b1;
        end
        perf_gmem_bytes <= perf_gmem_bytes + bytes_this_cycle;
        if (|g_grant) begin
            perf_gmem_trans <= perf_gmem_trans + 1;
        end
        if (|l_grant) begin
            perf_lds_cycles <= perf_lds_cycles + 1;
        end
        // Section 4.3, system register 10: "cycles the matrix unit has been
        // busy".  One per cycle the array does work, which is one per cycle
        // it is granted - the counter is the port, exactly as it is for the
        // two memory counters above.  `acc_zero` does not appear here: it
        // walks the accumulator file's write port but asks nothing of the
        // multipliers, and section 7.2's matrix utilisation is about the
        // multipliers.
        if (|m_grant) begin
            perf_mma_busy <= perf_mma_busy + 1;
        end
    end
end

// ---------------------------------------------------------------- the waves

genvar w;
generate
    for (w = 0; w < WAVES; w = w + 1) begin : wg
        localparam [31:0] ID = w;
        gpu16 #(
            .PROGRAM_ADDR_WIDTH(PROGRAM_ADDR_WIDTH),
            .DATA_INDEX_WIDTH(DATA_INDEX_WIDTH)
        ) w_inst (
            .clk(clk),
            .reset(reset),
            .kernel_arg_ptr(kernel_arg_ptr),
            .group_id_x(group_id_x),
            .group_id_y(group_id_y),
            .wave_id(wave_id_base + ID),
            .launch(launch[w]),
            .issue_request(w_issue_request[w]),
            .issue_grant(issue_grant[w]),
            .g_request(w_g_request[w]),
            .g_block(w_g_block[18*w+:18]),
            .g_write(w_g_write[w]),
            .g_byte_enable(w_g_byte_enable[64*w+:64]),
            .g_wdata(w_g_wdata[512*w+:512]),
            .g_rdata(g_rdata),
            .g_grant(g_grant[w]),
            .l_request(w_l_request[w]),
            .l_bank_write(w_l_bank_write[16*w+:16]),
            .l_bank_row(w_l_bank_row[112*w+:112]),
            .l_byte_enable(w_l_byte_enable[64*w+:64]),
            .l_wdata(w_l_wdata[512*w+:512]),
            .l_rdata(l_rdata),
            .l_grant(l_grant[w]),
            .barrier_wait(w_barrier_wait[w]),
            .barrier_release(barrier_release),
            .m_request(w_m_request[w]),
            .m_a(w_m_a[32*w+:32]),
            .m_b(w_m_b[512*w+:512]),
            .m_acc(w_m_acc[512*w+:512]),
            .m_zero(w_m_zero[w]),
            .m_result(m_result),
            .m_grant(m_grant[w]),
            .gmem_bytes_add(w_bytes_add[32*w+:32]),
            .perf_gmem_bytes_in(perf_gmem_bytes),
            .perf_gmem_trans_in(perf_gmem_trans),
            .perf_lds_cycles_in(perf_lds_cycles),
            .perf_mma_busy_in(perf_mma_busy),
            .halted(w_halted[w]),
            .prog_load_enable(prog_load_enable),
            .prog_load_address(prog_load_address),
            .prog_load_data(prog_load_data)
        );
    end
endgenerate

assign halted = &w_halted;

endmodule
