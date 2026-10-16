`timescale 1ns/1ps

// T_NUM_REQ_001: bit-exact comparison against model/requant_ref.py vectors.
module tb_requant_unit_num;
    localparam int MAX_VECTORS = 70000;

    logic clk = 0;
    logic rst_n = 0;
    logic signed [31:0] cfg_bias_q;
    logic signed [17:0] cfg_m0;
    logic [5:0] cfg_shift_n;
    logic cfg_relu, cfg_bypass;
    logic in_valid, in_ready;
    logic signed [31:0] in_acc;
    logic in_k_last, in_last;
    logic out_valid, out_ready;
    logic signed [7:0] out_y;
    logic signed [63:0] out_y_raw;
    logic out_last, out_sat, out_ovf;

    logic [31:0] count_mem [0:0];
    logic [31:0] acc_mem [0:MAX_VECTORS-1];
    logic [31:0] bias_mem [0:MAX_VECTORS-1];
    logic [17:0] m0_mem [0:MAX_VECTORS-1];
    logic [5:0] shift_mem [0:MAX_VECTORS-1];
    logic relu_mem [0:MAX_VECTORS-1];
    logic bypass_mem [0:MAX_VECTORS-1];
    logic k_last_mem [0:MAX_VECTORS-1];
    logic last_mem [0:MAX_VECTORS-1];
    logic [7:0] y_mem [0:MAX_VECTORS-1];
    logic [63:0] raw_mem [0:MAX_VECTORS-1];
    logic sat_mem [0:MAX_VECTORS-1];
    logic ovf_mem [0:MAX_VECTORS-1];
    integer accepted_indices [0:MAX_VECTORS-1];

    integer vector_count;
    integer current_index;
    integer q_head, q_tail, errors, checked;
    integer check_index;
    integer wait_cycles;
    integer scan_index;
    integer bypass_case_index, quant_case_index;

    always #5 clk = ~clk;

    requant_unit dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu),
        .cfg_bypass(cfg_bypass),
        .in_valid(in_valid), .in_ready(in_ready), .in_acc(in_acc),
        .in_k_last(in_k_last), .in_last(in_last),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_y(out_y), .out_y_raw(out_y_raw), .out_last(out_last),
        .out_sat(out_sat), .out_ovf(out_ovf)
    );

    // The driver leaves each word stable until its handshake. The monitor
    // queues only k_last words because the unit deliberately drops the other
    // handshakes without creating an output beat.
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if (in_valid && in_ready && in_k_last) begin
                accepted_indices[q_tail] = current_index;
                q_tail = q_tail + 1;
            end
            if (out_valid && out_ready) begin
                if (q_head >= q_tail) begin
                    $display("FAIL tb_requant_unit_num: unexpected output beat");
                    errors = errors + 1;
                end else begin
                    check_index = accepted_indices[q_head];
                    if ((out_y !== y_mem[check_index][7:0]) ||
                        (out_y_raw !== raw_mem[check_index]) ||
                        (out_sat !== sat_mem[check_index]) ||
                        (out_ovf !== ovf_mem[check_index]) ||
                        (out_last !== last_mem[check_index])) begin
                        $display("FAIL vector %0d: acc=%0d bias=%0d m0=%0d n=%0d relu=%0d bypass=%0d",
                                 check_index, $signed(acc_mem[check_index]),
                                 $signed(bias_mem[check_index]), m0_mem[check_index],
                                 shift_mem[check_index], relu_mem[check_index],
                                 bypass_mem[check_index]);
                        $display("  got: y=%0d raw=%h sat=%b ovf=%b last=%b",
                                 $signed(out_y), out_y_raw, out_sat, out_ovf, out_last);
                        $display("  exp: y=%0d raw=%h sat=%b ovf=%b last=%b",
                                 $signed(y_mem[check_index]), raw_mem[check_index],
                                 sat_mem[check_index], ovf_mem[check_index],
                                 last_mem[check_index]);
                        errors = errors + 1;
                    end
                    if ((check_index == bypass_case_index) && (out_sat !== 1'b0)) begin
                        $display("FAIL bypass status case: out_sat must be 0 for raw INT32 bypass");
                        errors = errors + 1;
                    end
                    if ((check_index == quant_case_index) && (out_sat !== 1'b1)) begin
                        $display("FAIL quantized status case: out_sat must be 1 for the same saturated a");
                        errors = errors + 1;
                    end
                    q_head = q_head + 1;
                    checked = checked + 1;
                end
            end
        end
    end

    initial begin
        $readmemh("../vectors/req_count.mem", count_mem);
        $readmemh("../vectors/req_acc.mem", acc_mem);
        $readmemh("../vectors/req_bias.mem", bias_mem);
        $readmemh("../vectors/req_m0.mem", m0_mem);
        $readmemh("../vectors/req_shift.mem", shift_mem);
        $readmemh("../vectors/req_relu.mem", relu_mem);
        $readmemh("../vectors/req_bypass.mem", bypass_mem);
        $readmemh("../vectors/req_k_last.mem", k_last_mem);
        $readmemh("../vectors/req_last.mem", last_mem);
        $readmemh("../vectors/req_y.mem", y_mem);
        $readmemh("../vectors/req_raw.mem", raw_mem);
        $readmemh("../vectors/req_sat.mem", sat_mem);
        $readmemh("../vectors/req_ovf.mem", ovf_mem);

        vector_count = count_mem[0];
        if (vector_count <= 0 || vector_count > MAX_VECTORS) begin
            $display("FAIL tb_requant_unit_num: invalid vector count %0d", vector_count);
            $finish(1);
        end

        bypass_case_index = -1;
        quant_case_index = -1;
        for (scan_index = 0; scan_index < vector_count; scan_index = scan_index + 1) begin
            if ((acc_mem[scan_index] == 32'd2000) &&
                (bias_mem[scan_index] == 32'd0) &&
                (m0_mem[scan_index] == 18'd131071) &&
                (shift_mem[scan_index] == 6'd20) &&
                (relu_mem[scan_index] == 1'b0)) begin
                if (bypass_mem[scan_index])
                    bypass_case_index = scan_index;
                else
                    quant_case_index = scan_index;
            end
        end
        if ((bypass_case_index < 0) || (quant_case_index < 0)) begin
            $display("FAIL tb_requant_unit_num: directed bypass saturation pair missing");
            $finish(1);
        end

        cfg_bias_q = '0;
        cfg_m0 = '0;
        cfg_shift_n = '0;
        cfg_relu = 1'b0;
        cfg_bypass = 1'b0;
        in_acc = '0;
        in_valid = 1'b0;
        in_k_last = 1'b0;
        in_last = 1'b0;
        out_ready = 1'b1;
        current_index = -1;
        q_head = 0;
        q_tail = 0;
        errors = 0;
        checked = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (current_index = 0; current_index < vector_count; current_index = current_index + 1) begin
            @(negedge clk);
            cfg_bias_q = bias_mem[current_index];
            cfg_m0 = m0_mem[current_index];
            cfg_shift_n = shift_mem[current_index];
            cfg_relu = relu_mem[current_index];
            cfg_bypass = bypass_mem[current_index];
            in_acc = acc_mem[current_index];
            in_k_last = k_last_mem[current_index];
            in_last = last_mem[current_index];
            in_valid = 1'b1;
            do begin
                @(posedge clk);
                #1;
            end while (!in_ready);
            @(negedge clk);
            in_valid = 1'b0;
        end

        @(negedge clk);
        in_valid = 1'b0;
        in_k_last = 1'b0;
        wait_cycles = 0;
        while ((checked < vector_count) && (wait_cycles < 100)) begin
            @(posedge clk);
            #1;
            wait_cycles = wait_cycles + 1;
        end

        if (checked != vector_count) begin
            $display("FAIL tb_requant_unit_num: checked %0d of %0d vectors", checked, vector_count);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS tb_requant_unit_num: %0d vectors", vector_count);
        else
            $display("FAIL tb_requant_unit_num: %0d errors", errors);
        $finish;
    end
endmodule
