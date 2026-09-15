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
    output [7:0] dig,
    output reg [5:0] sel
    );

    reg [36:0] counter;

    cpu_inst8_data8 U0(
    .clk(counter[20])
    );
    initial begin
        counter = 0;
    end
    
    reg [3:0] digits[5:0];
    reg [3:0] d;
    integer i;
    integer n;
    always @(posedge clk) begin
        counter = counter + 1;
        n = U0.registers[1];
        for (i = 0; i < 6; i=i+1) begin
            digits[i] = n % 10;
            if (sel[i] == 1'b0) begin
                d = digits[i];
            end
            n = n / 10;
        end
    end
    
    digital_tube U1(
    .dig(dig),
    .d(d)
    );
    
    initial begin
        sel = 8'b11111110;
    end
    
    always @(posedge counter[10]) begin
        sel = {sel[4:0], sel[5]};
    end
endmodule