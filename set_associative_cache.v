module set_associative_cache (
    input clk,
    input reset,

    input [15:0] addr,
    input [7:0] data_in,
    input read,
    input write,

    output reg [7:0] data_out,
    output reg hit,
    output reg miss,
    output reg busy, 

    output reg mem_read_en,
    output reg mem_write_en,
    output reg [15:0] mem_addr,
    output reg [7:0] mem_data_in,
    input [7:0] mem_data_out
);

    // Dynamic Parameterization
    parameter WAYS = 4;                // Can be switched between 2 or 4
    parameter NUM_SETS = 16;
    parameter BLOCK_SIZE_BYTES = 8;
    
    parameter OFFSET_BITS = 3;         // log_2(BLOCK_SIZE_BYTES)
    parameter INDEX_BITS = 4;          // log_2(NUM_SETS)
    parameter TAG_BITS = 9;            // 16 - INDEX_BITS - OFFSET_BITS
    parameter WAY_BITS = (WAYS == 4) ? 2 : 1; // Bit-width to index ways

    // Address Slicing driven directly by parameters
    wire [TAG_BITS-1:0] tag     = addr[15 : 16-TAG_BITS];
    wire [INDEX_BITS-1:0] index = addr[16-TAG_BITS-1 : OFFSET_BITS];
    wire [OFFSET_BITS-1:0] offset = addr[OFFSET_BITS-1 : 0];

    // Cache Arrays
    reg [TAG_BITS-1:0] tag_array [0:NUM_SETS-1][0:WAYS-1];
    reg valid_array [0:NUM_SETS-1][0:WAYS-1];
    reg [7:0] data_array [0:NUM_SETS-1][0:WAYS-1][0:BLOCK_SIZE_BYTES-1];
    
    // Age registers for Tracking Counter-Based LRU (2-bits for WAYS=4, 1-bit for WAYS=2)
    reg [WAY_BITS-1:0] age_array [0:NUM_SETS-1][0:WAYS-1];

    // Parametrizable Hit Detection
    reg is_hit;
    reg [WAY_BITS-1:0] hit_way;
    integer w;
    
    always @(*) begin
        is_hit = 0;
        hit_way = 0;
        for (w = 0; w < WAYS; w = w + 1) begin
            if (valid_array[index][w] && (tag_array[index][w] == tag)) begin
                is_hit = 1;
                hit_way = w;
            end
        end
    end

    // State Machine States
    parameter IDLE = 0, COMPARE = 1, READ_MISS_FETCH = 2, READ_MISS_WAIT = 3, 
              WRITE_THROUGH = 4, UPDATE_CACHE = 5;
    reg [2:0] state, next_state;

    reg [OFFSET_BITS:0] fetch_counter; 
    reg [WAY_BITS-1:0] lru_victim;
    reg latched_write; 
    reg [WAY_BITS-1:0] latched_hit_way;
    reg [15:0] latched_addr;
    reg [7:0] latched_data_in;
    reg latched_is_hit;
    
    integer i, j, k;

    // FSM Transitions
    always @(posedge clk or posedge reset) begin
        if (reset) state <= IDLE;
        else       state <= next_state;
    end
    
    // Find the oldest block (Max Age) to pick as victim
    reg [WAY_BITS-1:0] max_age_way;
    reg [WAY_BITS-1:0] current_max_age;
    integer v;
    always @(*) begin
        max_age_way = 0;
        current_max_age = 0;
        for (v = 0; v < WAYS; v = v + 1) begin
            if (age_array[index][v] >= current_max_age) begin
                current_max_age = age_array[index][v];
                max_age_way = v;
            end
        end
    end

    // Control Path State Registers
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            latched_write   <= 0;
            latched_hit_way <= 0;
            latched_is_hit  <= 0;
            latched_addr    <= 0;
            latched_data_in <= 0;
            fetch_counter   <= 0;
            lru_victim      <= 0;
        end else begin
            if (state == IDLE && (read || write)) begin
                latched_write   <= write; 
                latched_addr    <= addr;
                latched_data_in <= data_in;
            end
            
            if (state == COMPARE) begin
                latched_hit_way <= hit_way;
                latched_is_hit  <= is_hit;
                if (!is_hit) begin
                    lru_victim    <= max_age_way; // Dynamic selection based on age
                    fetch_counter <= 0;
                end
            end
            
            if (state == READ_MISS_WAIT) begin
                data_array[latched_addr[6:3]][lru_victim][fetch_counter[OFFSET_BITS-1:0]] <= mem_data_out;
                fetch_counter <= fetch_counter + 1;
            end
        end
    end

    // Combinational Output Router
    always @(*) begin
        next_state = state;
        hit = 0; miss = 0; busy = (state != IDLE);
        data_out = 8'hzz; mem_read_en = 0; mem_write_en = 0;
        mem_addr = 16'hzz; mem_data_in = 8'hzz;

        case (state)
            IDLE: if (read || write) next_state = COMPARE;

            COMPARE: begin
                if (is_hit) begin
                    hit = 1;
                    data_out = data_array[index][hit_way][offset];
                    next_state = latched_write ? WRITE_THROUGH : IDLE;
                end else begin 
                    miss = 1;
                    next_state = latched_write ? WRITE_THROUGH : READ_MISS_FETCH;
                end
            end
            
            READ_MISS_FETCH: begin
                mem_read_en = 1;
                mem_addr = {latched_addr[15:3], fetch_counter[OFFSET_BITS-1:0]};
                next_state = READ_MISS_WAIT;
            end
            
            READ_MISS_WAIT: begin
                if (fetch_counter == BLOCK_SIZE_BYTES) next_state = UPDATE_CACHE;
                else                                   next_state = READ_MISS_FETCH;
            end

            UPDATE_CACHE: begin 
                data_out = data_array[latched_addr[6:3]][lru_victim][latched_addr[2:0]];
                next_state = IDLE;
            end
            
            WRITE_THROUGH: begin 
                mem_write_en = 1;
                mem_addr = latched_addr;
                mem_data_in = latched_data_in;
                next_state = IDLE;
            end
            default: next_state = IDLE;
        endcase
    end

    // Unified LRU Counter Age Logic & Allocation Array Updates
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < NUM_SETS; i = i + 1) begin
                for (j = 0; j < WAYS; j = j + 1) begin
                    valid_array[i][j] <= 0;
                    tag_array[i][j]   <= 0;
                    age_array[i][j]   <= j; // Initialize with unique stacked priorities
                end
            end
        end else begin
            // LRU Counter Updates on Read Hit
            if (state == COMPARE && is_hit && !latched_write) begin
                for (k = 0; k < WAYS; k = k + 1) begin
                    if (k == hit_way) begin
                        age_array[index][k] <= 0; // Most recently used
                    end else if (age_array[index][k] < age_array[index][hit_way]) begin
                        age_array[index][k] <= age_array[index][k] + 1;
                    end
                end
            end

            // Write-Through Updates
            if (state == WRITE_THROUGH) begin
                if (latched_is_hit) begin 
                    data_array[latched_addr[6:3]][latched_hit_way][latched_addr[2:0]] <= latched_data_in;
                    // Update age for writes that hit
                    for (k = 0; k < WAYS; k = k + 1) begin
                        if (k == latched_hit_way) begin
                            age_array[latched_addr[6:3]][k] <= 0;
                        end else if (age_array[latched_addr[6:3]][k] < age_array[latched_addr[6:3]][latched_hit_way]) begin
                            age_array[latched_addr[6:3]][k] <= age_array[latched_addr[6:3]][k] + 1;
                        end
                    end
                end
            end

            // Allocation on Fetch Line complete
            if (state == UPDATE_CACHE) begin
                tag_array[latched_addr[6:3]][lru_victim]   <= latched_addr[15:7];
                valid_array[latched_addr[6:3]][lru_victim] <= 1;
                
                // Update age relative to the victimized line allocation
                for (k = 0; k < WAYS; k = k + 1) begin
                    if (k == lru_victim) begin
                        age_array[latched_addr[6:3]][k] <= 0;
                    end else if (age_array[latched_addr[6:3]][k] < age_array[latched_addr[6:3]][lru_victim]) begin
                        age_array[latched_addr[6:3]][k] <= age_array[latched_addr[6:3]][k] + 1;
                    end
                end
            end
        end
    end

endmodule
