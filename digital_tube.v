`include "cpu8.v"

module digital_tube(
    input [3:0] d,
    output reg [7:0] dig
);

always @(d) begin
    case (d)
        0: dig = 8'b11000000;
        1: dig = 8'b11111001;
        2: dig = 8'b10100100;
        3: dig = 8'b10110000;
        4: dig = 8'b10011001;
        5: dig = 8'b10010010;
        6: dig = 8'b10000010;
        7: dig = 8'b11111000;
        8: dig = 8'b10000000;
        9: dig = 8'b10010000;
        default: dig = 0;
    endcase
end

endmodule

// The board top: it runs the 8 bit CPU off a divided clock and shows r1 on a
// six digit seven segment display.  It used to instantiate a module called
// "main", which was renamed to cpu_inst8_data8 when main.v became cpu8.v, and
// it used to be called "test", which collided with the testbench in test.v.
module digital_tube_board(
    input clk,
    input reset,
    output [7:0] dig,
    output reg [5:0] sel
    );

    reg [36:0] counter;

    cpu_inst8_data8 U0(
    .clk(counter[20]),
    .reset(reset)
    );

    reg [3:0] digits[5:0];
    reg [3:0] d;
    integer i;
    integer n;
    integer digit;
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            counter <= 0;
            d <= 0;
            for (i = 0; i < 6; i=i+1) begin
                digits[i] <= 0;
            end
        end
        else begin
            counter <= counter + 1;
            // n and digit are working values, not state: they are written
            // before they are read on every pass, so a blocking assignment to
            // them is the correct way to describe the combinational chain.
            n = U0.registers[1];
            for (i = 0; i < 6; i=i+1) begin
                digit = n % 10;
                digits[i] <= digit[3:0];
                if (sel[i] == 1'b0) begin
                    d <= digit[3:0];
                end
                n = n / 10;
            end
        end
    end

    digital_tube U1(
    .dig(dig),
    .d(d)
    );

    always @(posedge counter[10] or posedge reset) begin
        if (reset) begin
            sel <= 6'b111110;
        end
        else begin
            sel <= {sel[4:0], sel[5]};
        end
    end
endmodule