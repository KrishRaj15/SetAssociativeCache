`timescale 1ns / 1ps

module tb_cache;

    reg clk;
    reg reset;
    reg [15:0] addr;
    reg [7:0] data_in;
    reg read;
    reg write;
    wire [7:0] mem_data_out;

    wire [7:0] data_out;
    wire hit;
    wire miss;
    wire busy;
    wire mem_read_en;
    wire mem_write_en;
    wire [15:0] mem_addr;
    wire [7:0] mem_data_in;

    set_associative_cache dut (
        .clk(clk),
        .reset(reset),
        .addr(addr),
        .data_in(data_in),
        .read(read),
        .write(write),
        .data_out(data_out),
        .hit(hit),
        .miss(miss),
        .busy(busy),
        .mem_read_en(mem_read_en),
        .mem_write_en(mem_write_en),
        .mem_addr(mem_addr),
        .mem_data_in(mem_data_in),
        .mem_data_out(mem_data_out)
    );

    main_memory mem (
        .clk(clk),
        .read_en(mem_read_en),
        .write_en(mem_write_en),
        .addr(mem_addr),
        .data_in(mem_data_in),
        .data_out(mem_data_out)
    );

    initial begin
        clk = 0;
    end
    always #5 clk = ~clk;
    
    initial begin
        $dumpfile("waveform.vcd");
        $dumpvars(0, tb_cache);
    end

    initial begin
        reset = 1;
        addr = 0;
        data_in = 0;
        read = 0;
        write = 0;
        
        #10 reset = 0;
        $display("Time\tEvent\tOp\tAddr\tData"); 

        read_op(16'h1234);
        wait_busy();

        read_op(16'h1234);
        wait_busy();

        write_op(16'h1235, 8'hAA);
        wait_busy();

        read_op(16'h1235);
        wait_busy();

        read_op(16'h2234); 
        wait_busy();

        read_op(16'h3234); 
        wait_busy();

        read_op(16'h1234);
        wait_busy();

        #50 $dumpoff;
        $finish;
    end
    
    task read_op(input [15:0] r_addr);
        begin
            #10;
            read <= 1;
            write <= 0;
            addr <= r_addr;
            $display("%0t\tCMD\tRD\t%h", $time, r_addr);
            #10;
            read <= 0;
        end
    endtask
    
    task write_op(input [15:0] w_addr, input [7:0] w_data);
        begin
            #10;
            read <= 0;
            write <= 1;
            addr <= w_addr;
            data_in <= w_data;
            $display("%0t\tCMD\tWR\t%h", $time, w_addr);
            #10;
            write <= 0;
        end
    endtask

    task wait_busy;
        reg r_hit;
        reg r_miss;
        reg [7:0] r_data_out;
        begin
            wait (hit == 1 || miss == 1);
            
            r_hit = hit;
            r_miss = miss;
            r_data_out = data_out;
            
            wait (busy == 0);
            
            if (r_hit)
                $display("%0t\tRESULT\tHIT\t%h\t%h", $time, addr, r_data_out);
            if (r_miss)
                $display("%0t\tRESULT\tMISS\t%h", $time, addr);
        end
    endtask
    
endmodule
