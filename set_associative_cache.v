module set_associative_cache #(
    parameter ADDR_WIDTH       = 16,
    parameter DATA_WIDTH       = 8,
    parameter WAYS             = 4,
    parameter NUM_SETS         = 16,
    parameter BLOCK_SIZE_BYTES = 8
)(
    input  wire                  clk,
    input  wire                  reset,

    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire [DATA_WIDTH-1:0] data_in,
    input  wire                  read,
    input  wire                  write,

    output reg  [DATA_WIDTH-1:0] data_out,
    output reg                   hit,
    output reg                   miss,
    output wire                  busy,
    output reg                   done,
    output wire                  req_ready,

    output reg                   mem_read_en,
    output reg                   mem_write_en,
    output reg  [ADDR_WIDTH-1:0] mem_addr,
    output reg  [DATA_WIDTH-1:0] mem_data_in,
    input  wire [DATA_WIDTH-1:0] mem_data_out
);

    localparam OFFSET_BITS = $clog2(BLOCK_SIZE_BYTES);
    localparam INDEX_BITS  = $clog2(NUM_SETS);
    localparam TAG_BITS    = ADDR_WIDTH - OFFSET_BITS - INDEX_BITS;
    localparam WAY_BITS    = (WAYS > 1) ? $clog2(WAYS) : 1;

    localparam [2:0] IDLE            = 3'd0,
                     COMPARE         = 3'd1,
                     READ_MISS_FETCH = 3'd2,
                     READ_MISS_WAIT  = 3'd3,
                     UPDATE_CACHE    = 3'd4,
                     WRITE_THROUGH   = 3'd5;

    reg [2:0] state, next_state;

    reg [TAG_BITS-1:0]   tag_array   [0:NUM_SETS-1][0:WAYS-1];
    reg                  valid_array [0:NUM_SETS-1][0:WAYS-1];
    reg [DATA_WIDTH-1:0] data_array  [0:NUM_SETS-1][0:WAYS-1][0:BLOCK_SIZE_BYTES-1];
    reg [WAY_BITS-1:0]   age_array   [0:NUM_SETS-1][0:WAYS-1];

    reg [ADDR_WIDTH-1:0]  latched_addr;
    reg [DATA_WIDTH-1:0]  latched_data_in;
    reg                   latched_write;
    reg                   latched_is_hit;
    reg [WAY_BITS-1:0]    latched_hit_way;
    reg [WAY_BITS-1:0]    lru_victim;
    reg [OFFSET_BITS-1:0] fetch_counter;

    wire [TAG_BITS-1:0]    l_tag    = latched_addr[ADDR_WIDTH-1 : OFFSET_BITS+INDEX_BITS];
    wire [INDEX_BITS-1:0]  l_index  = latched_addr[OFFSET_BITS+INDEX_BITS-1 : OFFSET_BITS];
    wire [OFFSET_BITS-1:0] l_offset = latched_addr[OFFSET_BITS-1 : 0];

    assign busy      = (state != IDLE);
    assign req_ready = (state == IDLE);

    initial begin
        if (WAYS < 1 || (WAYS & (WAYS - 1)) != 0) begin
            $display("ERROR: WAYS must be a power of 2 >= 1");
            $finish;
        end
        if (NUM_SETS < 2 || (NUM_SETS & (NUM_SETS - 1)) != 0) begin
            $display("ERROR: NUM_SETS must be a power of 2 >= 2");
            $finish;
        end
        if (BLOCK_SIZE_BYTES < 2 || (BLOCK_SIZE_BYTES & (BLOCK_SIZE_BYTES - 1)) != 0) begin
            $display("ERROR: BLOCK_SIZE_BYTES must be a power of 2 >= 2");
            $finish;
        end
        if (TAG_BITS < 1) begin
            $display("ERROR: Invalid address configuration (TAG_BITS < 1)");
            $finish;
        end
    end

    reg                is_hit;
    reg [WAY_BITS-1:0] hit_way;
    integer w;

    always @(*) begin
        is_hit  = 1'b0;
        hit_way = {WAY_BITS{1'b0}};

        for (w = 0; w < WAYS; w = w + 1) begin
            if (valid_array[l_index][w] && (tag_array[l_index][w] == l_tag)) begin
                is_hit  = 1'b1;
                hit_way = w[WAY_BITS-1:0];
            end
        end
    end

    reg [WAY_BITS-1:0] victim_way, max_age;
    reg                found_invalid;
    integer v;

    always @(*) begin
        victim_way    = {WAY_BITS{1'b0}};
        max_age       = {WAY_BITS{1'b0}};
        found_invalid = 1'b0;

        for (v = 0; v < WAYS; v = v + 1) begin
            if (!valid_array[l_index][v] && !found_invalid) begin
                victim_way    = v[WAY_BITS-1:0];
                found_invalid = 1'b1;
            end
        end

        if (!found_invalid) begin
            for (v = 0; v < WAYS; v = v + 1) begin
                if (age_array[l_index][v] >= max_age) begin
                    max_age    = age_array[l_index][v];
                    victim_way = v[WAY_BITS-1:0];
                end
            end
        end
    end

    always @(posedge clk or posedge reset) begin
        if (reset)
            state <= IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        next_state   = state;
        hit          = 1'b0;
        miss         = 1'b0;
        done         = 1'b0;
        data_out     = {DATA_WIDTH{1'b0}};
        mem_read_en  = 1'b0;
        mem_write_en = 1'b0;
        mem_addr     = {ADDR_WIDTH{1'b0}};
        mem_data_in  = {DATA_WIDTH{1'b0}};

        case (state)
            IDLE: begin
                if (read || write)
                    next_state = COMPARE;
            end

            COMPARE: begin
                if (is_hit) begin
                    hit = 1'b1;
                    if (!latched_write) begin
                        data_out   = data_array[l_index][hit_way][l_offset];
                        done       = 1'b1;
                        next_state = IDLE;
                    end else begin
                        next_state = WRITE_THROUGH;
                    end
                end else begin
                    miss       = 1'b1;
                    next_state = latched_write ? WRITE_THROUGH : READ_MISS_FETCH;
                end
            end

            READ_MISS_FETCH: begin
                mem_read_en = 1'b1;
                mem_addr    = {latched_addr[ADDR_WIDTH-1 : OFFSET_BITS], fetch_counter};
                next_state  = READ_MISS_WAIT;
            end

            READ_MISS_WAIT: begin
                if (fetch_counter == BLOCK_SIZE_BYTES - 1)
                    next_state = UPDATE_CACHE;
                else
                    next_state = READ_MISS_FETCH;
            end

            UPDATE_CACHE: begin
                data_out   = data_array[l_index][lru_victim][l_offset];
                done       = 1'b1;
                next_state = IDLE;
            end

            WRITE_THROUGH: begin
                mem_write_en = 1'b1;
                mem_addr     = latched_addr;
                mem_data_in  = latched_data_in;
                done         = 1'b1;
                next_state   = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    integer i, j, k;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            latched_addr    <= {ADDR_WIDTH{1'b0}};
            latched_data_in <= {DATA_WIDTH{1'b0}};
            latched_write   <= 1'b0;
            latched_is_hit  <= 1'b0;
            latched_hit_way <= {WAY_BITS{1'b0}};
            lru_victim      <= {WAY_BITS{1'b0}};
            fetch_counter   <= {OFFSET_BITS{1'b0}};

            for (i = 0; i < NUM_SETS; i = i + 1) begin
                for (j = 0; j < WAYS; j = j + 1) begin
                    valid_array[i][j] <= 1'b0;
                    tag_array[i][j]   <= {TAG_BITS{1'b0}};
                    age_array[i][j]   <= j[WAY_BITS-1:0];
                end
            end
        end else begin
            if (state == IDLE && (read || write)) begin
                latched_addr    <= addr;
                latched_data_in <= data_in;
                latched_write   <= write && !read;
            end

            if (state == COMPARE) begin
                latched_is_hit  <= is_hit;
                latched_hit_way <= hit_way;

                if (is_hit && !latched_write) begin
                    for (k = 0; k < WAYS; k = k + 1) begin
                        if (k[WAY_BITS-1:0] == hit_way)
                            age_array[l_index][k] <= {WAY_BITS{1'b0}};
                        else if (age_array[l_index][k] < age_array[l_index][hit_way])
                            age_array[l_index][k] <= age_array[l_index][k] + 1'b1;
                    end
                end else if (!is_hit && !latched_write) begin
                    lru_victim    <= victim_way;
                    fetch_counter <= {OFFSET_BITS{1'b0}};
                end
            end

            if (state == READ_MISS_WAIT) begin
                if (fetch_counter == BLOCK_SIZE_BYTES - 1)
                    fetch_counter <= {OFFSET_BITS{1'b0}};
                else
                    fetch_counter <= fetch_counter + 1'b1;
            end

            if (state == WRITE_THROUGH && latched_is_hit) begin
                for (k = 0; k < WAYS; k = k + 1) begin
                    if (k[WAY_BITS-1:0] == latched_hit_way)
                        age_array[l_index][k] <= {WAY_BITS{1'b0}};
                    else if (age_array[l_index][k] < age_array[l_index][latched_hit_way])
                        age_array[l_index][k] <= age_array[l_index][k] + 1'b1;
                end
            end

            if (state == UPDATE_CACHE) begin
                tag_array[l_index][lru_victim]   <= l_tag;
                valid_array[l_index][lru_victim] <= 1'b1;

                for (k = 0; k < WAYS; k = k + 1) begin
                    if (k[WAY_BITS-1:0] == lru_victim)
                        age_array[l_index][k] <= {WAY_BITS{1'b0}};
                    else if (age_array[l_index][k] < age_array[l_index][lru_victim])
                        age_array[l_index][k] <= age_array[l_index][k] + 1'b1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (state == READ_MISS_WAIT) begin
            data_array[l_index][lru_victim][fetch_counter] <= mem_data_out;
        end else if (state == WRITE_THROUGH && latched_is_hit) begin
            data_array[l_index][latched_hit_way][l_offset] <= latched_data_in;
        end
    end

endmodule
