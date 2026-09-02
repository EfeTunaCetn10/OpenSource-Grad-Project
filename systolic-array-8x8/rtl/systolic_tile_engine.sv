`timescale 1ns/1ps

// Reference tile engine around the reusable array core.
// A is row-major ROWS x K_MAX, B is row-major K_MAX x COLS.
// Runtime dimensions enable zero-padded partial tiles.
module systolic_tile_engine #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int K_MAX      = 8,
    parameter int DATA_WIDTH = 8,
    parameter int ACC_WIDTH  = 32,
    parameter int ROW_W      = $clog2(ROWS+1),
    parameter int COL_W      = $clog2(COLS+1),
    parameter int K_W        = $clog2(K_MAX+1),
    parameter int RUN_W      = $clog2(K_MAX+ROWS+COLS)
) (
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                start,
    output logic                                start_ready,
    input  logic [ROW_W-1:0]                    active_rows,
    input  logic [COL_W-1:0]                    active_cols,
    input  logic [K_W-1:0]                      k_len,
    input  logic [ROWS*K_MAX*DATA_WIDTH-1:0]    a_matrix_flat,
    input  logic [K_MAX*COLS*DATA_WIDTH-1:0]    b_matrix_flat,
    output logic                                busy,
    output logic                                done,
    output logic                                c_valid,
    output logic                                config_error,
    output logic [ROWS*COLS*ACC_WIDTH-1:0]      c_matrix_flat,
    output logic [ROWS*COLS-1:0]                mac_fire_flat
);
    typedef enum logic [2:0] {IDLE, CLEAR, RUN, CAPTURE} state_t;
    state_t state;

    logic [ROWS*K_MAX*DATA_WIDTH-1:0] a_tile_reg;
    logic [K_MAX*COLS*DATA_WIDTH-1:0] b_tile_reg;
    logic [ROW_W-1:0] rows_reg;
    logic [COL_W-1:0] cols_reg;
    logic [K_W-1:0]   k_reg;
    logic [RUN_W-1:0] run_cycle;
    logic [RUN_W-1:0] run_last;

    logic [ROWS*DATA_WIDTH-1:0] a_left_flat;
    logic [COLS*DATA_WIDTH-1:0] b_top_flat;
    logic [ROWS-1:0]            a_left_valid;
    logic [COLS-1:0]            b_top_valid;
    logic [ROWS*COLS*ACC_WIDTH-1:0] array_c_flat;

    logic array_step;
    logic array_clear;
    logic array_flush;

    assign start_ready = (state == IDLE);
    assign busy        = (state != IDLE);
    assign array_step  = (state == RUN);
    assign array_clear = (state == CLEAR);
    assign array_flush = (state == CLEAR);

    // Time-skewed edge injection. A[r,k] is launched at t=r+k;
    // B[k,c] is launched at t=c+k. They meet at PE[r,c].
    integer ri;
    integer ci;
    integer k_index;
    always_comb begin
        ri             = 0;
        ci             = 0;
        k_index        = 0;
        a_left_flat  = '0;
        b_top_flat   = '0;
        a_left_valid = '0;
        b_top_valid  = '0;

        if (state == RUN) begin
            for (ri = 0; ri < ROWS; ri++) begin
                if ((ri < int'(rows_reg)) && (int'(run_cycle) >= ri) &&
                    ((int'(run_cycle)-ri) < int'(k_reg))) begin
                    k_index = int'(run_cycle)-ri;
                    a_left_flat[ri*DATA_WIDTH +: DATA_WIDTH] =
                        a_tile_reg[(ri*K_MAX+k_index)*DATA_WIDTH +: DATA_WIDTH];
                    a_left_valid[ri] = 1'b1;
                end
            end

            for (ci = 0; ci < COLS; ci++) begin
                if ((ci < int'(cols_reg)) && (int'(run_cycle) >= ci) &&
                    ((int'(run_cycle)-ci) < int'(k_reg))) begin
                    k_index = int'(run_cycle)-ci;
                    b_top_flat[ci*DATA_WIDTH +: DATA_WIDTH] =
                        b_tile_reg[(k_index*COLS+ci)*DATA_WIDTH +: DATA_WIDTH];
                    b_top_valid[ci] = 1'b1;
                end
            end
        end
    end

    systolic_array_os #(
        .ROWS      (ROWS),
        .COLS      (COLS),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_array (
        .clk           (clk),
        .rst_n         (rst_n),
        .step          (array_step),
        .clear_acc     (array_clear),
        .pipe_flush    (array_flush),
        .a_left_flat   (a_left_flat),
        .a_left_valid  (a_left_valid),
        .b_top_flat    (b_top_flat),
        .b_top_valid   (b_top_valid),
        .c_acc_flat    (array_c_flat),
        .mac_fire_flat (mac_fire_flat)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state         <= IDLE;
            a_tile_reg    <= '0;
            b_tile_reg    <= '0;
            rows_reg      <= '0;
            cols_reg      <= '0;
            k_reg         <= '0;
            run_cycle     <= '0;
            run_last      <= '0;
            c_matrix_flat <= '0;
            done          <= 1'b0;
            c_valid       <= 1'b0;
            config_error  <= 1'b0;
        end else begin
            done         <= 1'b0;
            c_valid      <= 1'b0;
            config_error <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        if ((active_rows == 0) || (int'(active_rows) > ROWS) ||
                            (active_cols == 0) || (int'(active_cols) > COLS) ||
                            (k_len == 0) || (int'(k_len) > K_MAX)) begin
                            config_error <= 1'b1;
                        end else begin
                            a_tile_reg <= a_matrix_flat;
                            b_tile_reg <= b_matrix_flat;
                            rows_reg   <= active_rows;
                            cols_reg   <= active_cols;
                            k_reg      <= k_len;
                            run_last   <= k_len + active_rows + active_cols - 3;
                            state      <= CLEAR;
                        end
                    end
                end

                CLEAR: begin
                    run_cycle <= '0;
                    state     <= RUN;
                end

                RUN: begin
                    if (run_cycle == run_last)
                        state <= CAPTURE;
                    else
                        run_cycle <= run_cycle + 1'b1;
                end

                CAPTURE: begin
                    c_matrix_flat <= array_c_flat;
                    done          <= 1'b1;
                    c_valid       <= 1'b1;
                    state         <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
