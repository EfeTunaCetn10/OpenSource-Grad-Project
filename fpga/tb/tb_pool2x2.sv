`timescale 1ns/1ps

module pool_case #(
    parameter int IN_H = 28,
    parameter int IN_W = 28,
    parameter int C_LOGICAL = 6,
    parameter int CASE_ID = 1
) (
    input logic clk,
    input logic rst_n,
    input int mutant,
    output logic done
);
    localparam int TILES = (C_LOGICAL+7)/8;
    localparam int IN_BEATS = TILES*IN_H*IN_W;
    localparam int OUT_BEATS = TILES*(IN_H/2)*(IN_W/2);
    localparam logic [5:0] CFG_IN_H = IN_H;
    localparam logic [5:0] CFG_IN_W = IN_W;
    localparam logic [2:0] CFG_C_TILES = TILES;
    logic [63:0] frame_mem [0:IN_BEATS-1];
    logic [63:0] expected_mem [0:OUT_BEATS-1];
    logic s_valid, s_ready, m_valid, m_ready, m_last, cfg_error;
    logic [63:0] s_data, m_data;
    logic [15:0] lfsr;
    int sent, received;
    logic was_stalled;
    logic [63:0] stalled_data;
    logic stalled_last;
    logic [63:0] expected;

    initial begin
        if (CASE_ID == 1) begin
            $readmemh("../vectors/p1_frame.mem", frame_mem);
            $readmemh("../vectors/p1_y.mem", expected_mem);
        end else begin
            $readmemh("../vectors/p2_frame.mem", frame_mem);
            $readmemh("../vectors/p2_y.mem", expected_mem);
        end
    end

    pool2x2 dut (
        .clk(clk), .rst_n(rst_n), .cfg_in_h(CFG_IN_H),
        .cfg_in_w(CFG_IN_W), .cfg_c_tiles(CFG_C_TILES),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_last(s_valid && sent == IN_BEATS-1),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data), .m_last(m_last),
        .cfg_error(cfg_error)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= CASE_ID == 1 ? 16'hACE1 : 16'hC00D;
            sent <= 0;
            received <= 0;
            s_valid <= 0;
            s_data <= '0;
            m_ready <= 0;
            done <= 0;
            was_stalled <= 0;
            stalled_data <= '0;
            stalled_last <= 0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            m_ready <= lfsr[0] | lfsr[3];

            if (s_valid && s_ready) begin
                sent <= sent + 1;
                s_valid <= 0;
            end else if (!s_valid && sent < IN_BEATS && (lfsr[1] | lfsr[5])) begin
                s_data <= frame_mem[sent];
                s_valid <= 1;
            end

            if (was_stalled && (!m_valid || m_data !== stalled_data ||
                                m_last !== stalled_last)) begin
                $display("FAIL pool case %0d output changed under stall", CASE_ID);
                $fatal(1, "output changed under stall");
            end
            was_stalled <= m_valid && !m_ready;
            if (m_valid && !m_ready) begin
                stalled_data <= m_data;
                stalled_last <= m_last;
            end

            if (m_valid && m_ready) begin
                if (cfg_error) begin
                    $display("FAIL pool case %0d unexpected cfg_error", CASE_ID);
                    $fatal(1, "unexpected pool config error");
                end
                if (received >= OUT_BEATS) begin
                    $display("FAIL pool case %0d extra output %h", CASE_ID, m_data);
                    $fatal(1, "extra output");
                end
                expected = expected_mem[received];
                if (mutant == 1)
                    expected = expected_mem[(received+1) % OUT_BEATS];
                else if (mutant == 2)
                    expected = expected ^ 64'h0000000000000080;
                else if (mutant == 3)
                    expected = {expected[63:16], expected[7:0], expected[15:8]};
                if (m_data !== expected || m_last !== (received == OUT_BEATS-1)) begin
                    $display("FAIL pool case %0d beat %0d got=%h expected=%h last=%b expected_last=%b mutant=%0d",
                             CASE_ID, received, m_data, expected, m_last,
                             received == OUT_BEATS-1, mutant);
                    $fatal(1, "pool value mismatch");
                end
                received <= received + 1;
                if (received == OUT_BEATS-1) begin
                    if (sent != IN_BEATS) begin
                        $display("FAIL pool case %0d input count %0d expected %0d",
                                 CASE_ID, sent, IN_BEATS);
                        $fatal(1, "input count mismatch");
                    end
                    done <= 1;
                end
            end
        end
    end
endmodule

module tb_pool2x2;
    logic clk = 0;
    logic rst_n = 0;
    logic done1, done2;
    int mutant;
    int cycles;
    always #5 clk = ~clk;

    pool_case #(.IN_H(28), .IN_W(28), .C_LOGICAL(6), .CASE_ID(1)) p1
        (.clk(clk), .rst_n(rst_n), .mutant(mutant), .done(done1));
    pool_case #(.IN_H(10), .IN_W(10), .C_LOGICAL(16), .CASE_ID(2)) p2
        (.clk(clk), .rst_n(rst_n), .mutant(mutant), .done(done2));

    initial begin
        mutant = 0;
        if ($test$plusargs("MUTANT1")) mutant = 1;
        if ($test$plusargs("MUTANT2")) mutant = 2;
        if ($test$plusargs("MUTANT3")) mutant = 3;
        repeat (4) @(posedge clk);
        rst_n = 1;
        cycles = 0;
        while (!(done1 && done2) && cycles < 200000) begin
            @(posedge clk);
            cycles++;
        end
        if (!(done1 && done2)) begin
            $display("FAIL pool timeout done1=%b done2=%b", done1, done2);
            $fatal(1, "pool timeout");
        end
        repeat (4) @(posedge clk);
        if (p1.m_valid || p2.m_valid) begin
            $display("FAIL pool extra valid after completion");
            $fatal(1, "extra output after completion");
        end
        $display("PASS tb_pool2x2: pool1=%0d beats pool2=%0d beats, cycles=%0d",
                 p1.OUT_BEATS, p2.OUT_BEATS, cycles);
        $finish;
    end
endmodule
