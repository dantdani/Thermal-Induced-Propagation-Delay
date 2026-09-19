`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// thermolab_top.sv (v2.00) -- CS1410 Lab 1b: delay vs temperature
// Board: Opal Kelly XEM7310-A75 (xc7a75tfgg484-1), FrontPanel USB 3.0
//
// Sensor  : 7-pad IOBUF pad-loopback ring on unused MC1 expansion pins,
//           bank 13 (fixed 3.3 V), weak drive / slow slew.
// Control : 33-stage LUT ring, pblocked near die center.
// Heater  : v2.00 -- three REGIONAL fabric heaters A/B/C (LUT+FF toggle
//           cells + DSP48 MACCs at 403.2 MHz), one-hot selected, duty-PWM
//           with hardware soft-start and a VCCINT governor. USB power only:
//           no external supply, no BRAM banks, no I/O-pad heater.
//           Hardware-blocked unless the XADC is provably alive; killed by
//           the 85 C fabric guard and the XADC OT backstop.
// Temp    : XADC Wizard IP (xadc_wiz_0, DRP) polled by xadc_mon.
//
// FrontPanel endpoint map (v2.00)
//   WireIn  0x00 : ctrl   [0] ring_io_en   [1] ring_lut_en
//                         [2] heater_en    [3] pause_heater_during_window
//   WireIn  0x01 : heater [2:0] select {A,B,C} (one-hot, A>B>C priority)
//                         [15:8] duty request 0..255
//   WireIn  0x02 : measurement window length in okClk cycles
//                         (0 -> default 1,008,000 = 10.000 ms @ 100.8 MHz)
//   TrigIn  0x40 : bit 0 = start one measurement window
//   WireOut 0x20 : ring_io  cycle count over the window (valid when done=1)
//   WireOut 0x21 : ring_lut cycle count over the window (valid when done=1)
//   WireOut 0x22 : [11:0] live XADC temperature code
//                         T(degC) = code*503.975/4096 - 273.15
//   WireOut 0x23 : status [31:16]=16'hA5C3 magic  [15:8]=duty_applied
//                         [7]=xadc_sensor_ok [6]=heat_alive [5]=heater_any
//                         [4]=mmcm_locked [3]=xadc_OT
//                         [2]=alarm_hot(85C w/ 60C hysteresis)
//                         [1]=done [0]=busy
//   WireOut 0x24 : [11:0] live XADC VCCINT code, V = code*3.0/4096
//   WireOut 0x25 : design signature 32'h544C_0200 ("TL" v2.00)
//   WireOut 0x26 : XADC diagnostics {eoc_cnt[15:0], drdy_cnt[15:0]}
//   WireOut 0x27 : governor {duty_cap[31:24], duty_applied[23:16],
//                            12'b0, vlow_now[3], sel_onehot[2:0]}
//=============================================================================
module thermolab_top (
    input  wire [4:0]   okUH,
    output wire [2:0]   okHU,
    inout  wire [31:0]  okUHU,
    inout  wire         okAA,

    inout  wire [20:0]   ring_pad,    // sensor: MC1 bank-13 pads (3.3 V)
    output wire [2:0]   led_status   // LED D6..D8 = {alarm, heater_any, busy} (active low)
);

    // ------------------------------------------------------------------
    // FrontPanel host interface
    // ------------------------------------------------------------------
    wire         okClk;             // ~100.8 MHz, crystal-derived, T-stable
    wire [112:0] okHE;
    wire [64:0]  okEH;

    okHost okHI (
        .okUH(okUH), .okHU(okHU), .okUHU(okUHU), .okAA(okAA),
        .okClk(okClk), .okHE(okHE), .okEH(okEH)
    );

    localparam integer NWO = 8;
    wire [65*NWO-1:0] okEHx;
    okWireOR #(.N(NWO)) wireOR (.okEH(okEH), .okEHx(okEHx));

    wire [31:0] w_ctrl, w_heat, w_winlen, trig;
    okWireIn    wi00 (.okHE(okHE), .ep_addr(8'h00), .ep_dataout(w_ctrl));
    okWireIn    wi01 (.okHE(okHE), .ep_addr(8'h01), .ep_dataout(w_heat));
    okWireIn    wi02 (.okHE(okHE), .ep_addr(8'h02), .ep_dataout(w_winlen));
    okTriggerIn ti40 (.okHE(okHE), .ep_addr(8'h40), .ep_clk(okClk), .ep_trigger(trig));

    // ------------------------------------------------------------------
    // Measurement window generator (okClk domain, hardware-timed)
    // ------------------------------------------------------------------
    wire [31:0] winlen = (w_winlen == 32'd0) ? 32'd1_008_000 : w_winlen;

    reg        busy       = 1'b0;
    reg        done       = 1'b0;
    reg [31:0] wcnt       = 32'd0;
    reg [9:0]  settle     = 10'd0;
    reg        cap_strobe = 1'b0;

    always @(posedge okClk) begin
        cap_strobe <= 1'b0;
        if (trig[0] && !busy && (settle == 10'd0)) begin
            busy <= 1'b1;
            done <= 1'b0;
            wcnt <= winlen;
        end else if (busy) begin
            wcnt <= wcnt - 32'd1;
            if (wcnt == 32'd1) begin
                busy   <= 1'b0;
                settle <= 10'd1;         // let ring-domain sync flush (~5 us)
            end
        end else if (settle != 10'd0) begin
            settle <= settle + 10'd1;
            if (settle == 10'd512) begin
                settle     <= 10'd0;
                cap_strobe <= 1'b1;      // counters are static now: capture
                done       <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Delay sensors: I/O-loopback ring (signal) + LUT ring (control)
    // ------------------------------------------------------------------
    wire ring_io_raw, ring_lut_raw;

    ring_io  #(.N_PADS(21))  u_ring_io  (.pad(ring_pad), .enable(w_ctrl[0]), .ring_out(ring_io_raw));
    ring_lut #(.N_INV(32))  u_ring_lut (.enable(w_ctrl[1]), .ring_out(ring_lut_raw));

    wire clk_ring_io, clk_ring_lut;
    BUFG u_bufg_ring_io  (.I(ring_io_raw),  .O(clk_ring_io));
    BUFG u_bufg_ring_lut (.I(ring_lut_raw), .O(clk_ring_lut));

    wire [31:0] cnt_io, cnt_lut;
    freq_counter u_cnt_io (
        .clk_ring(clk_ring_io), .okClk(okClk),
        .window_ok(busy), .cap_strobe(cap_strobe), .value(cnt_io)
    );
    freq_counter u_cnt_lut (
        .clk_ring(clk_ring_lut), .okClk(okClk),
        .window_ok(busy), .cap_strobe(cap_strobe), .value(cnt_lut)
    );

    // ------------------------------------------------------------------
    // Heater clock: okClk 100.8 MHz -> 403.2 MHz  (VCO = 806.4 MHz).
    // NO BUFG here: the heater has one BUFGCE per region (clock-tree
    // gating IS part of the heater). Fallback if bench-flaky: MULT 10.0,
    // CLKOUT0_DIVIDE 3.0 -> 336 MHz.
    // ------------------------------------------------------------------
    wire mmcm_fb, clk403_raw, mmcm_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD   (9.921),      // 100.8 MHz
        .CLKFBOUT_MULT_F (8.000),      // VCO 806.4 MHz (600-1200 legal on -1)
        .DIVCLK_DIVIDE   (1),
        .CLKOUT0_DIVIDE_F(2.000)       // 403.2 MHz
    ) u_mmcm (
        .CLKIN1(okClk), .CLKFBIN(mmcm_fb), .CLKFBOUT(mmcm_fb), .CLKFBOUTB(),
        .CLKOUT0(clk403_raw), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(mmcm_locked), .RST(1'b0), .PWRDWN(1'b0)
    );

    // ------------------------------------------------------------------
    // XADC die-temperature monitor + thermal guards + liveness
    // ------------------------------------------------------------------
    wire [11:0] temp_code, vccint_code;
    wire        ot;          // XADC over-temperature (125 C backstop)
    wire        alarm_hot;   // fabric comparator: >=85 C set, <60 C clear
    wire        sensor_ok;   // XADC provably converting within last ~125 ms
    wire [15:0] drdy_cnt, eoc_cnt;

    xadc_mon u_xadc (
        .okClk(okClk),
        .temp_code(temp_code), .vccint_code(vccint_code),
        .ot(ot), .alarm_hot(alarm_hot), .sensor_ok(sensor_ok),
        .drdy_cnt(drdy_cnt), .eoc_cnt(eoc_cnt)
    );

    // ------------------------------------------------------------------
    // Regional heaters A/B/C: one-hot select + duty PWM + soft-start +
    // VCCINT governor, all inside u_heater (heater.sv v2.00).
    // NEVER heats with a blind thermometer: sensor_ok is required.
    // ------------------------------------------------------------------
    wire heat_ok = w_ctrl[2] & mmcm_locked & sensor_ok & ~ot & ~alarm_hot;
    wire pause   = w_ctrl[3] & busy;     // optional quasi-static windows

    wire [2:0] sel_onehot;
    wire [7:0] duty_applied, duty_cap;
    wire       vlow_now, heater_any, heat_alive;

    heater u_heater (
        .okClk        (okClk),
        .clk_fast_raw (clk403_raw),
        .heat_ok      (heat_ok),
        .pause        (pause),
        .sel_req      (w_heat[2:0]),
        .duty_req     (w_heat[15:8]),
        .vccint_code  (vccint_code),
        .sel_onehot   (sel_onehot),
        .duty_applied (duty_applied),
        .duty_cap     (duty_cap),
        .vlow_now     (vlow_now),
        .heater_any   (heater_any),
        .alive        (heat_alive)
    );

    // ------------------------------------------------------------------
    // Status, wire-outs, LEDs
    // ------------------------------------------------------------------
    wire [31:0] status = {16'hA5C3, duty_applied,
                          sensor_ok, heat_alive, heater_any, mmcm_locked,
                          ot, alarm_hot, done, busy};
    wire [31:0] gov    = {duty_cap, duty_applied, 12'd0, vlow_now, sel_onehot};

    okWireOut wo20 (.okHE(okHE), .okEH(okEHx[0*65 +: 65]), .ep_addr(8'h20), .ep_datain(cnt_io));
    okWireOut wo21 (.okHE(okHE), .okEH(okEHx[1*65 +: 65]), .ep_addr(8'h21), .ep_datain(cnt_lut));
    okWireOut wo22 (.okHE(okHE), .okEH(okEHx[2*65 +: 65]), .ep_addr(8'h22), .ep_datain({20'd0, temp_code}));
    okWireOut wo23 (.okHE(okHE), .okEH(okEHx[3*65 +: 65]), .ep_addr(8'h23), .ep_datain(status));
    okWireOut wo24 (.okHE(okHE), .okEH(okEHx[4*65 +: 65]), .ep_addr(8'h24), .ep_datain({20'd0, vccint_code}));
    okWireOut wo25 (.okHE(okHE), .okEH(okEHx[5*65 +: 65]), .ep_addr(8'h25), .ep_datain(32'h544C_0200));
    okWireOut wo26 (.okHE(okHE), .okEH(okEHx[6*65 +: 65]), .ep_addr(8'h26), .ep_datain({eoc_cnt, drdy_cnt}));
    okWireOut wo27 (.okHE(okHE), .okEH(okEHx[7*65 +: 65]), .ep_addr(8'h27), .ep_datain(gov));

    // XEM7310 LEDs light when driven low
    assign led_status = ~{(alarm_hot | ot), heater_any, busy};

endmodule
`default_nettype wire