`timescale 1ns/1ps

// Hand-written AXI4-Lite register file for the Stage 1 control plane.
//
// The parameter registers are deliberately split into shadow and active
// storage.  A software-visible commit is the only operation that copies a
// complete, validated shadow image into the active image.
module axi_lite_regs #(
    parameter int ADDR_W = 12
) (
    input  logic                  clk,
    input  logic                  rst_n,

    input  logic [ADDR_W-1:0]     s_axi_awaddr,
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [31:0]           s_axi_wdata,
    input  logic [3:0]            s_axi_wstrb,
    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    output logic [1:0]            s_axi_bresp,
    output logic                  s_axi_bvalid,
    input  logic                  s_axi_bready,

    input  logic [ADDR_W-1:0]     s_axi_araddr,
    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    output logic [31:0]           s_axi_rdata,
    output logic [1:0]            s_axi_rresp,
    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,

    // Datapath status and performance counters.
    input  logic                  busy,
    input  logic                  done,
    input  logic [31:0]           cycle_count,
    input  logic [31:0]           stall_in,
    input  logic [31:0]           stall_out,
    input  logic [31:0]           frame_count,
    input  logic                  table_valid,
    // TODO Stage 2: add the BRAM/table parameter bundle and select it in the
    // cfg_* mux when TILE_CFG.PARAM_SRC=1.  Until then table_valid is the
    // explicit validity contract that prevents an all-zero table start.
    // Bits are the ERROR register bits.  Internal commit/start checks are
    // generated in this block; this input carries datapath-originated error
    // events and is useful for the W1C contract.
    input  logic [7:0]            hw_error_set,

    // One-cycle control events.  START and SOFT_RESET are never readable as
    // level bits; these pulses are the consumer-facing side of those W1S bits.
    output logic                  start,
    output logic                  soft_reset,
    output logic                  counter_clear,

    // Active, committed parameter image.  Unpacked arrays are used so one
    // requant_unit can connect directly to each bank without a packing shim.
    output logic signed [31:0]    cfg_bias_q [0:7],
    output logic signed [17:0]    cfg_m0     [0:7],
    output logic        [5:0]     cfg_shift_n[0:7],
    output logic                  cfg_relu   [0:7],
    output logic                  cfg_bypass,
    output logic [8:0]            cfg_c_in,
    output logic [2:0]            cfg_kh,
    output logic [2:0]            cfg_kw,
    output logic [1:0]            cfg_stride,
    output logic [1:0]            cfg_pad,
    output logic [5:0]            cfg_out_h,
    output logic [5:0]            cfg_out_w,
    output logic [7:0]            cfg_tile_idx,
    output logic [7:0]            cfg_tile_count,
    output logic                  cfg_param_src,
    output logic [15:0]           cfg_k_len
);

    // Version fields are intentionally local to this block so a map change
    // cannot be made without leaving a visible software version trace.
    localparam logic [15:0] RTL_VERSION    = 16'h0001;
    localparam logic [15:0] REGMAP_VERSION = 16'h0001;

    localparam logic [ADDR_W-1:0] A_VERSION      = 12'h000;
    localparam logic [ADDR_W-1:0] A_CONTROL      = 12'h004;
    localparam logic [ADDR_W-1:0] A_STATUS       = 12'h008;
    localparam logic [ADDR_W-1:0] A_ERROR        = 12'h00C;
    localparam logic [ADDR_W-1:0] A_LAYER_CFG    = 12'h010;
    localparam logic [ADDR_W-1:0] A_TILE_CFG     = 12'h014;
    localparam logic [ADDR_W-1:0] A_PARAM_BASE   = 12'h040;
    localparam logic [ADDR_W-1:0] A_PARAM_END    = 12'h0BC;
    localparam logic [ADDR_W-1:0] A_COMMIT       = 12'h0C0;
    localparam logic [ADDR_W-1:0] A_PARAM_STATUS = 12'h0C4;
    localparam logic [ADDR_W-1:0] A_CYCLE_COUNT  = 12'h100;
    localparam logic [ADDR_W-1:0] A_STALL_IN     = 12'h104;
    localparam logic [ADDR_W-1:0] A_STALL_OUT    = 12'h108;
    localparam logic [ADDR_W-1:0] A_FRAME_COUNT  = 12'h10C;

    logic [30:0] layer_cfg_reg;
    logic [17:0] tile_cfg_reg;
    logic        irq_en;

    logic signed [31:0] shadow_bias_q [0:7];
    logic signed [17:0] shadow_m0     [0:7];
    logic        [5:0]  shadow_shift_n [0:7];
    logic               shadow_relu   [0:7];

    logic signed [31:0] active_bias_q [0:7];
    logic signed [17:0] active_m0     [0:7];
    logic        [5:0]  active_shift_n[0:7];
    logic               active_relu   [0:7];

    logic [23:0] written_mask;
    logic        committed;
    logic        done_latched;
    logic [7:0]  error_latched;

    logic        aw_hold;
    logic [ADDR_W-1:0] awaddr_hold;
    logic        w_hold;
    logic [31:0] wdata_hold;
    logic [3:0]  wstrb_hold;

    logic        ar_take;
    logic        aw_take;
    logic        w_take;
    logic        write_complete;
    logic [ADDR_W-1:0] write_addr;
    logic [31:0] write_data;
    logic [3:0]  write_strb;
    logic [3:0]  write_bank;
    logic [1:0]  write_word;

    logic [7:0]  error_set_this_cycle;
    logic [7:0]  error_w1c_mask;
    logic        done_w1c;
    logic        commit_accept;
    logic        write_param;
    logic [31:0] layer_merged;

    integer i;
    integer j;
    integer k;

    function automatic logic [31:0] merge_wstrb(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strb
    );
        integer b;
        begin
            merge_wstrb = old_value;
            for (b = 0; b < 4; b = b + 1)
                if (strb[b])
                    merge_wstrb[b*8 +: 8] = new_value[b*8 +: 8];
        end
    endfunction

    function automatic logic [17:0] merge_m0(
        input logic [17:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strb
    );
        logic [31:0] merged;
        begin
            merged = merge_wstrb({14'h0, old_value}, new_value, strb);
            merge_m0 = merged[17:0];
        end
    endfunction

    function automatic logic [5:0] merge_shift(
        input logic [5:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strb
    );
        logic [31:0] merged;
        begin
            merged = merge_wstrb({26'h0, old_value}, new_value, strb);
            merge_shift = merged[5:0];
        end
    endfunction

    function automatic logic [17:0] merge_tile(
        input logic [17:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  strb
    );
        logic [31:0] merged;
        begin
            merged = merge_wstrb({14'h0, old_value}, new_value, strb);
            merge_tile = merged[17:0];
        end
    endfunction

    function automatic logic [31:0] read_mux(input logic [ADDR_W-1:0] addr);
        integer bank;
        begin
            read_mux = 32'h0000_0000;
            case (addr)
                A_VERSION: begin
                    read_mux[31:16] = RTL_VERSION;
                    read_mux[15:0]  = REGMAP_VERSION;
                end
                A_CONTROL: begin
                    read_mux[2] = irq_en;
                end
                A_STATUS: begin
                    read_mux[0] = !busy;
                    read_mux[1] = busy;
                    read_mux[2] = done_latched;
                    read_mux[3] = |error_latched;
                    // Extension required by the PARAM_SRC=1 start guard.
                    // It occupies a previously reserved status bit.
                    read_mux[4] = table_valid;
                end
                A_ERROR: begin
                    read_mux[7:0] = error_latched;
                end
                A_LAYER_CFG: begin
                    read_mux = {1'b0, layer_cfg_reg};
                end
                A_TILE_CFG: begin
                    read_mux[17:0] = tile_cfg_reg;
                end
                A_PARAM_STATUS: begin
                    read_mux[23:0] = written_mask;
                    read_mux[24]   = committed;
                end
                A_CYCLE_COUNT: read_mux = cycle_count;
                A_STALL_IN:    read_mux = stall_in;
                A_STALL_OUT:   read_mux = stall_out;
                A_FRAME_COUNT: read_mux = frame_count;
                default: begin
                    if ((addr >= A_PARAM_BASE) && (addr <= A_PARAM_END) &&
                        (addr[1:0] == 2'b00) && (addr[3:2] != 2'b11)) begin
                        bank = (addr - A_PARAM_BASE) >> 4;
                        case (addr[3:2])
                            2'd0: read_mux = active_bias_q[bank];
                            2'd1: read_mux[17:0] = active_m0[bank];
                            2'd2: begin
                                read_mux[5:0] = active_shift_n[bank];
                                read_mux[8]   = active_relu[bank];
                            end
                            default: read_mux = 32'h0;
                        endcase
                    end
                end
            endcase
        end
    endfunction

    always_comb begin
        s_axi_awready = !aw_hold && !s_axi_bvalid;
        s_axi_wready  = !w_hold  && !s_axi_bvalid;
        s_axi_arready = !s_axi_rvalid;

        aw_take = s_axi_awvalid && s_axi_awready;
        w_take  = s_axi_wvalid  && s_axi_wready;
        ar_take = s_axi_arvalid && s_axi_arready;

        write_complete = !s_axi_bvalid &&
                         (aw_hold || aw_take) && (w_hold || w_take);
        write_addr = aw_hold ? awaddr_hold : s_axi_awaddr;
        write_data = w_hold  ? wdata_hold  : s_axi_wdata;
        write_strb = w_hold  ? wstrb_hold  : s_axi_wstrb;
        write_bank = (write_addr - A_PARAM_BASE) >> 4;
        write_word = write_addr[3:2];
        layer_merged = merge_wstrb({1'b0, layer_cfg_reg}, write_data,
                                   write_strb);

        write_param = write_complete &&
                      (write_addr >= A_PARAM_BASE) &&
                      (write_addr <= A_PARAM_END) &&
                      (write_addr[1:0] == 2'b00) &&
                      (write_addr[3:2] != 2'b11);

        error_w1c_mask = 8'h00;
        if (write_complete && (write_addr == A_ERROR) && write_strb[0])
            error_w1c_mask = write_data[7:0];

        done_w1c = write_complete && (write_addr == A_STATUS) &&
                   write_strb[0] && write_data[2];

        error_set_this_cycle = hw_error_set;

        // Hardware wins over software W1C when both happen on one clock.
        // These checks intentionally use the pre-write state, as the AXI
        // write itself is the event being validated.
        if (write_complete && (write_addr == A_COMMIT) &&
            write_strb[0] && write_data[0]) begin
            if (busy) begin
                error_set_this_cycle[3] = 1'b1;
            end else begin
                if (written_mask != 24'hFF_FFFF)
                    error_set_this_cycle[7] = 1'b1;
                for (j = 0; j < 8; j = j + 1)
                    if (($unsigned(shadow_m0[j]) < 18'd65536) ||
                        ($unsigned(shadow_m0[j]) >= 18'd131072))
                        error_set_this_cycle[0] = 1'b1;
            end
        end

        if (write_complete && (write_addr == A_CONTROL) &&
            write_strb[0] && write_data[0] && !busy) begin
            if (tile_cfg_reg[17] ? !table_valid : !committed)
                error_set_this_cycle[7] = 1'b1;
        end

        commit_accept = write_complete && (write_addr == A_COMMIT) &&
                        write_strb[0] && write_data[0] && !busy &&
                        (written_mask == 24'hFF_FFFF);
        for (j = 0; j < 8; j = j + 1)
            if (($unsigned(shadow_m0[j]) < 18'd65536) ||
                ($unsigned(shadow_m0[j]) >= 18'd131072))
                commit_accept = 1'b0;
    end

    always_comb begin
        for (k = 0; k < 8; k = k + 1) begin
            cfg_bias_q[k]  = active_bias_q[k];
            cfg_m0[k]      = active_m0[k];
            cfg_shift_n[k] = active_shift_n[k];
            cfg_relu[k]    = active_relu[k];
        end
        cfg_bypass = tile_cfg_reg[16];
        cfg_c_in = layer_cfg_reg[8:0];
        cfg_kh = layer_cfg_reg[11:9];
        cfg_kw = layer_cfg_reg[14:12];
        cfg_stride = layer_cfg_reg[16:15];
        cfg_pad = layer_cfg_reg[18:17];
        cfg_out_h = layer_cfg_reg[24:19];
        cfg_out_w = layer_cfg_reg[30:25];
        cfg_tile_idx = tile_cfg_reg[7:0];
        cfg_tile_count = tile_cfg_reg[15:8];
        cfg_param_src = tile_cfg_reg[17];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            layer_cfg_reg <= '0;
            cfg_k_len <= '0;
            tile_cfg_reg <= 18'h0;
            irq_en <= 1'b0;
            written_mask <= 24'h0;
            committed <= 1'b0;
            done_latched <= 1'b0;
            error_latched <= 8'h0;
            aw_hold <= 1'b0;
            awaddr_hold <= '0;
            w_hold <= 1'b0;
            wdata_hold <= '0;
            wstrb_hold <= '0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp <= 2'b00;
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= 32'h0;
            s_axi_rresp <= 2'b00;
            start <= 1'b0;
            soft_reset <= 1'b0;
            counter_clear <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                shadow_bias_q[i] <= '0;
                shadow_m0[i] <= '0;
                shadow_shift_n[i] <= '0;
                shadow_relu[i] <= 1'b0;
                active_bias_q[i] <= '0;
                active_m0[i] <= '0;
                active_shift_n[i] <= '0;
                active_relu[i] <= 1'b0;
            end
        end else begin
            start <= 1'b0;
            soft_reset <= 1'b0;
            counter_clear <= 1'b0;

            // A datapath event is latched.  W1C is applied first, then the
            // event is ORed back in, so an event cannot be lost.
            done_latched <= (done_latched && !done_w1c) || done;
            error_latched <= (error_latched & ~error_w1c_mask) |
                             error_set_this_cycle;

            if (aw_take) begin
                aw_hold <= 1'b1;
                awaddr_hold <= s_axi_awaddr;
            end
            if (w_take) begin
                w_hold <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (write_complete) begin
                aw_hold <= 1'b0;
                w_hold <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= 2'b00;

                if (write_param) begin
                    written_mask[write_bank*3 + write_word] <= 1'b1;
                    case (write_word)
                        2'd0: shadow_bias_q[write_bank] <=
                                  $signed(merge_wstrb(shadow_bias_q[write_bank],
                                                       write_data, write_strb));
                        2'd1: shadow_m0[write_bank] <=
                                  $signed(merge_m0(shadow_m0[write_bank],
                                                    write_data, write_strb));
                        2'd2: begin
                            shadow_shift_n[write_bank] <=
                                merge_shift(shadow_shift_n[write_bank],
                                            write_data, write_strb);
                            if (write_strb[1])
                                shadow_relu[write_bank] <= write_data[8];
                        end
                        default: begin end
                    endcase
                end

                case (write_addr)
                    A_CONTROL: begin
                        if (write_strb[0]) begin
                            irq_en <= write_data[2];
                            if (write_data[0] && !busy &&
                                (tile_cfg_reg[17] ? table_valid : committed))
                                start <= 1'b1;
                            if (write_data[1]) begin
                                soft_reset <= 1'b1;
                                counter_clear <= 1'b1;
                            end
                        end
                    end
                    A_LAYER_CFG: begin
                        layer_cfg_reg <= layer_merged[30:0];
                    end
                    A_TILE_CFG: begin
                        tile_cfg_reg <= merge_tile(tile_cfg_reg, write_data,
                                                   write_strb);
                    end
                    A_COMMIT: begin
                        if (commit_accept) begin
                            // Geometry is stable before a later START.  The
                            // bounded 9x3x3 product is sampled only on commit.
                            cfg_k_len <= cfg_c_in * cfg_kh * cfg_kw;
                            for (i = 0; i < 8; i = i + 1) begin
                                active_bias_q[i] <= shadow_bias_q[i];
                                active_m0[i] <= shadow_m0[i];
                                active_shift_n[i] <= shadow_shift_n[i];
                                active_relu[i] <= shadow_relu[i];
                            end
                            committed <= 1'b1;
                            written_mask <= 24'h0;
                        end
                    end
                    default: begin end
                endcase
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;
            if (ar_take) begin
                s_axi_rdata <= read_mux(s_axi_araddr);
                s_axi_rresp <= 2'b00;
                s_axi_rvalid <= 1'b1;
            end
        end
    end

endmodule
