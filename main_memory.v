
module main_memory (
    input clk,
    input read_en,
    input write_en,
    input [15:0] addr,
    input [7:0] data_in,
    output reg [7:0] data_out
);

    reg [7:0] mem [0:65535];
    
    integer i;

    always @(posedge clk) begin
        if (read_en) begin
            data_out <= mem[addr];
        end
        if (write_en) begin
            mem[addr] <= data_in;
        end
    end
    
    initial begin
        for (i = 0; i < 65536; i = i + 1) begin
            mem[i] = i[7:0]; 
        end
    end
    
endmodule