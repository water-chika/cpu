module memory(
   input clk,
   input write_enable,
   input enable,
   input [7:0] address,
   input [7:0] in_data,
   output reg [7:0] out_data
);

reg [7:0] mem[255:0];

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
