module memory_ramb18e1(
   input clk,
   input write_enable,
   input read_enable,
   input address,
   input in_data,
   output out_data
);

wire clk;
wire write_enable;
wire read_enable;
wire [7:0] address;
wire [7:0] in_data;
wire [7:0] out_data;

RAMB18E1 mem(
.ADDRARDADDR(address),
.ENARDEN(read_enable),
.CLKARDCLK(clk),
.DOADO(out_data)
);

always @(posedge clk) begin
    if (write_enable) begin
        //mem[address] = in_data;
    end
    else begin
    end
end

//assign out_data = read_enable ? mem[address] : 0;


initial begin
    //$monitor("write_enable=%b, read_enable=%b, address=%8b, in_data=%8b, out_data=%8b",
    //    write_enable, read_enable, address, in_data, out_data);
end

endmodule