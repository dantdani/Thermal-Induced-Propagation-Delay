`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// xadc_mon.sv (v3) -- wraps the XADC WIZARD IP (component name: xadc_wiz_0),
// i.e., the configuration you already proved reads well on this board.
//
// ---------------------------------------------------------------------------
// CREATE THE IP (IP Catalog -> FPGA Features -> XADC Wizard), settings:
//
//   Component name           : xadc_wiz_0          (must match exactly)
//   Basic tab:
//     Interface option       : DRP                 (NOT AXI4Lite!)
//     Startup channel select : Channel Sequencer
//     Timing mode            : Continuous
//     DCLK frequency         : 100.8 MHz
//     ADC conversion rate    : leave default (wizard picks a legal divider;
//                              if it complains, set 900 KSPS)
//     Control/Status ports   : check "EOC" (eoc_out). Leave reset_in
//                              UNCHECKED. Others unchecked.
//   ADC Setup tab:
//     Sequencer mode         : Continuous
//     Channel averaging      : 16
//   Alarms tab:
//     Over Temperature alarm : ENABLED (gives ot_out); thresholds default
//                              (125 C). Other alarms off.
//   Channel Sequencer tab:
//     check Temperature and VCCINT (and their "average" boxes if shown)
//
// The 85 C heater-kill does NOT depend on wizard alarm settings -- a fabric
// comparator on the temperature code handles it, with OT as backstop.
// ---------------------------------------------------------------------------
//
// DRP FSM alternately reads Temperature (0x00) and VCCINT (0x01) every
// ~0.65 ms, with a watchdog so a missed DRDY can never deadlock the poller.
//
// Diagnostics / fail-safe:
//   * eoc_cnt  : counts end-of-conversion pulses (frozen = ADC not converting)
//   * drdy_cnt : counts completed DRP reads     (frozen = DRP handshake dead)
//   * sensor_ok: EOC seen within the last ~125 ms; the top level refuses to
//                enable the heater unless this is high.
//
// T(degC) = code * 503.975 / 4096 - 273.15
//   85.0 C -> 0xB5F     60.1 C -> 0xA94
//=============================================================================
module xadc_mon (
    input  wire        okClk,
    output reg  [11:0] temp_code   = 12'd0,
    output reg  [11:0] vccint_code = 12'd0,
    output wire        ot,
    output reg         alarm_hot   = 1'b0,
    output reg         sensor_ok   = 1'b0,
    output reg  [15:0] drdy_cnt    = 16'd0,
    output reg  [15:0] eoc_cnt     = 16'd0
);

    localparam [11:0] TH_HOT  = 12'hB5F;   // ~85.0 C
    localparam [11:0] TH_COOL = 12'hA94;   // ~60.1 C

    reg  [6:0]  daddr    = 7'h00;
    reg         den      = 1'b0;
    wire        drdy, eoc;
    wire [15:0] dout;
    reg  [15:0] tick     = 16'd0;
    reg         sel      = 1'b0;           // 0: temp, 1: vccint
    reg         wait_rdy = 1'b0;
    reg  [7:0]  wdog     = 8'd0;
    reg  [23:0] eoc_age  = 24'hFFFFFF;     // saturating; starts "stale"

    always @(posedge okClk) begin
        den  <= 1'b0;
        tick <= tick + 16'd1;

        // ---- DRP poller with watchdog -------------------------------------
        if (!wait_rdy) begin
            if (tick == 16'd0) begin
                daddr    <= sel ? 7'h01 : 7'h00;
                den      <= 1'b1;
                wait_rdy <= 1'b1;
                wdog     <= 8'd0;
            end
        end else begin
            wdog <= wdog + 8'd1;
            if (drdy) begin
                drdy_cnt <= drdy_cnt + 16'd1;
                if (sel) vccint_code <= dout[15:4];
                else     temp_code   <= dout[15:4];
                sel      <= ~sel;
                wait_rdy <= 1'b0;
            end else if (wdog == 8'hFF) begin
                wait_rdy <= 1'b0;          // abandon this read; retry next tick
            end
        end

        // ---- ADC liveness -------------------------------------------------
        if (eoc) begin
            eoc_cnt <= eoc_cnt + 16'd1;
            eoc_age <= 24'd0;
        end else if (eoc_age != 24'hFFFFFF) begin
            eoc_age <= eoc_age + 24'd1;
        end
        sensor_ok <= (eoc_age < 24'hC00000);   // EOC seen within ~125 ms

        // ---- 85 C guard with hysteresis ------------------------------------
        if      (temp_code >= TH_HOT)  alarm_hot <= 1'b1;
        else if (temp_code <  TH_COOL) alarm_hot <= 1'b0;
    end

    // ------------------------------------------------------------------
    // XADC Wizard instance (see header for the exact IP settings).
    // If your generated core also has a reset_in port, either regenerate
    // with reset unchecked or add:  .reset_in(1'b0),
    // ------------------------------------------------------------------
    xadc_wiz_0 u_xadc_wiz (
        .dclk_in (okClk),
        .daddr_in(daddr),
        .den_in  (den),
        .dwe_in  (1'b0),
        .di_in   (16'h0000),
        .do_out  (dout),
        .drdy_out(drdy),
        .vp_in   (1'b0),
        .vn_in   (1'b0),
        .eoc_out (eoc),
        .ot_out  (ot)
    );

endmodule
`default_nettype wire