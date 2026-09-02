`timescale 1ns/1ps

module tb_pe_os;
    logic clk = 0;
    logic rst_n = 0;
    logic step = 0;
    logic clear_acc = 0;
    logic pipe_flush = 0;
    logic signed [7:0] a_in = 0;
    logic signed [7:0] b_in = 0;
    logic a_valid_in = 0;
    logic b_valid_in = 0;
    logic signed [7:0] a_out;
    logic signed [7:0] b_out;
    logic a_valid_out;
    logic b_valid_out;
    logic signed [31:0] acc_out;
    logic mac_fire;
    integer errors = 0;

    always #5 clk = ~clk;

    pe_os dut (.*);

    task automatic tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic expect_acc(input integer signed expected, input [255:0] label_text);
        begin
            if ($signed(acc_out) !== expected) begin
                $display("FAIL %0s: got %0d expected %0d", label_text, $signed(acc_out), expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        tick();
        tick();
        rst_n = 1;

        clear_acc = 1;
        pipe_flush = 1;
        tick();
        clear_acc = 0;
        pipe_flush = 0;

        step = 1;
        a_valid_in = 1;
        b_valid_in = 1;
        a_in = -128;
        b_in = 127;
        tick();
        expect_acc(-16256, "signed boundary");
        if (($signed(a_out) !== -128) || ($signed(b_out) !== 127) || !mac_fire) begin
            $display("FAIL registered forwarding or mac_fire");
            errors = errors + 1;
        end

        a_in = -128;
        b_in = -128;
        tick();
        expect_acc(128, "second accumulate");

        step = 0;
        a_in = 12;
        b_in = 11;
        tick();
        expect_acc(128, "global stall");

        step = 1;
        a_valid_in = 0;
        tick();
        expect_acc(128, "invalid bubble");

        clear_acc = 1;
        tick();
        expect_acc(0, "clear accumulator");

        clear_acc = 0;
        pipe_flush = 1;
        tick();
        if (a_valid_out || b_valid_out) begin
            $display("FAIL pipe flush: forwarded valids were not cleared");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS tb_pe_os");
        else
            $display("FAIL tb_pe_os: %0d errors", errors);
        $finish;
    end
endmodule
