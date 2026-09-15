module memory #(
   parameter DATA_WIDTH = 8,
   parameter ADDR_WIDTH = 8,
   parameter RAM_DEPTH = 1 << ADDR_WIDTH
) (
   input clk,
   input write_enable,
   input enable,
   input [ADDR_WIDTH-1:0] address,
   input [DATA_WIDTH-1:0] in_data,
   output reg [DATA_WIDTH-1:0] out_data
);

reg [DATA_WIDTH-1:0] mem[0:RAM_DEPTH-1];

always @(posedge clk) begin
    if (enable) begin
        if (write_enable) begin
            mem[address] = in_data;
        end
        out_data = mem[address];
    end
end

initial begin
    //$monitor("write_enable=%b, read_enable=%b, address=%8b, in_data=%8b, out_data=%8b",
    //    write_enable, read_enable, address, in_data, out_data);
end

endmodule
