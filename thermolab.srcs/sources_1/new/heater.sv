// ============================================================================
// heater.sv -- Thermolab v2.00: three REGIONAL die heaters, USB-only power.
// Top module keeps the name `heater`; the port list changes at u_heater.
//   * One heater at a time (one-hot, A > B > C priority)
//   * ~98 kHz duty PWM + soft-start (0 -> full ~0.33 s)
//   * VCCINT governor: <0.970 V sheds duty, <0.938 V dumps to zero,
//     slow recovery -- a weak USB port self-limits instead of browning out
//   * Per region: N_CELL LUT1+FF toggle cells + N_DSP DSP48 MACCs, own
//     BUFGCE on the 403.2 MHz MMCM output (off = clock tree dark)
// Clock contract: clk_fast_raw = MMCM CLKOUT0 PRE-BUFG at 403.2 MHz
//   (CLKFBOUT_MULT_F=8.0, DIVCLK_DIVIDE=1, CLKOUT0_DIVIDE_F=2.0).
//   Fallback 336 MHz: MULT 10.0, DIVIDE 3.0.
// Heater datapaths are thermal, not logical (false-pathed in the XDC).
// ============================================================================

`default_nettype none

// ---------------------------------------------------------------- toggle cells
module heater_cellblock #(
    parameter int N = 9000
)(
    input  wire  clk,          // region-gated 403.2 MHz
    output logic t0            // one toggle bit, for the alive monitor
);
    (* DONT_TOUCH = "true" *) logic [N-1:0] t = '0;
    (* DONT_TOUCH = "true" *) wire  [N-1:0] tn;

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_cell
            LUT1 #(.INIT(2'b01)) u_inv (.O(tn[i]), .I0(t[i]));   // O = ~I0
            always_ff @(posedge clk) t[i] <= tn[i];
        end
    endgenerate
    assign t0 = t[0];
endmodule

// ---------------------------------------------------------------- DSP heaters
module heater_dspblock #(
    parameter int N = 40
)(
    input wire clk
);
    (* DONT_TOUCH = "true" *) logic [31:0] lfsr = 32'hACE1_2497;
    always_ff @(posedge clk)
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};

    genvar i;
    generate
        for (i = 0; i < N; i++) begin : g_dsp
            (* use_dsp = "yes", DONT_TOUCH = "true" *)
            logic signed [47:0] acc = '0;
            logic signed [17:0] a = '0, b = '0;
            always_ff @(posedge clk) begin
                a   <= signed'({lfsr[17:0]}  ^ 18'(i * 7 + 1));
                b   <= signed'({lfsr[31:14]} ^ 18'(i * 13 + 3));
                acc <= acc + a * b;            // MACC: mult + 48-bit add
            end
        end
    endgenerate
endmodule

// ---------------------------------------------------------------- one region
module heater_region #(
    parameter int N_CELL = 9000,
    parameter int N_DSP  = 40
)(
    input  wire  clk_fast_raw,   // MMCM output, pre-BUFG
    input  wire  gate,           // okClk-domain PWM gate (BUFGCE CE is glitchless)
    output logic alive_fast      // toggling while the region clock runs
);
    wire clk_r;
    BUFGCE u_bufg (.O(clk_r), .CE(gate), .I(clk_fast_raw));

    heater_cellblock #(.N(N_CELL)) u_cells (.clk(clk_r), .t0(alive_fast));
    heater_dspblock  #(.N(N_DSP))  u_dsps  (.clk(clk_r));
endmodule

// ------------------------------------------------------------ the heater bank
module heater #(
    parameter int N_CELL_A = 9000, parameter int N_DSP_A = 40,
    parameter int N_CELL_B = 9000, parameter int N_DSP_B = 40,
    parameter int N_CELL_C = 9000, parameter int N_DSP_C = 40,
    // VCCINT governor thresholds (12-bit XADC code, V = code/4096*3)
    parameter logic [11:0] TH_VLOW = 12'h52C,   // 0.970 V: sag -> shed duty
    parameter logic [11:0] TH_VPANIC = 12'h500, // 0.938 V: dump duty to 0
    // timebases (okClk powers of two; small values only for simulation)
    parameter int LOG2_PWM  = 2,    // PWM advance every 4 okClk -> ~98 kHz PWM
    parameter int LOG2_SLEW = 17,   // soft-start step ~1.3 ms -> full in ~0.33 s
    parameter int LOG2_GOV  = 20    // governor step ~10.4 ms
)(
    input  wire         okClk,
    input  wire         clk_fast_raw,     // 403.2 MHz MMCM output, pre-BUFG
    input  wire         heat_ok,          // xadc_alive & locked & ~ot & ~hot
    input  wire         pause,            // busy window & ctrl[3]
    input  wire  [2:0]  sel_req,          // WireIn 0x01 [2:0] = {A,B,C}
    input  wire  [7:0]  duty_req,         // WireIn 0x01 [15:8] = duty 0..255
    input  wire  [11:0] vccint_code,      // live from xadc_mon
    output logic [2:0]  sel_onehot,
    output logic [7:0]  duty_applied,     // after soft-start + governor
    output logic [7:0]  duty_cap,         // governor ceiling
    output logic        vlow_now,
    output logic        heater_any,
    output logic        alive             // okClk-domain proof of toggling
);
    // ---- one-hot select (A > B > C priority; multi-set requests demoted)
    always_comb begin
        casez (sel_req)
            3'b1??:  sel_onehot = 3'b100;   // A
            3'b01?:  sel_onehot = 3'b010;   // B
            3'b001:  sel_onehot = 3'b001;   // C
            default: sel_onehot = 3'b000;
        endcase
    end

    // ---- shared timebase off okClk. PWM ~98 kHz: board caps average the
    //      chopped load (VCCINT sees duty x P, not on/off steps).
    logic [LOG2_GOV-1:0] tbase = '0;
    always_ff @(posedge okClk) tbase <= tbase + 1'b1;
    wire pwm_tick  = (tbase[LOG2_PWM-1:0]  == '0);
    wire slew_tick = (tbase[LOG2_SLEW-1:0] == '0);
    wire gstep     = (tbase                == '0);

    // ---- VCCINT governor: sag -> shed (16/step, ~10 ms/step); panic ->
    //      dump to zero in one okClk; healthy -> slow recovery (~10 s full).
    logic [7:0] cap_q  = 8'hFF;      // governor ceiling, starts wide open
    logic [1:0] healthy_cnt = '0;
    assign duty_cap = cap_q;
    assign vlow_now = (vccint_code < TH_VLOW);
    wire   vpanic   = (vccint_code < TH_VPANIC);

    always_ff @(posedge okClk) begin
        if (!heat_ok || vpanic) begin
            cap_q       <= 8'd0;            // hard dump; recover from zero
            healthy_cnt <= '0;
        end else if (gstep) begin
            if (vlow_now) begin
                cap_q       <= (cap_q > 8'd16) ? cap_q - 8'd16 : 8'd0;
                healthy_cnt <= '0;
            end else if (cap_q != 8'hFF) begin
                healthy_cnt <= healthy_cnt + 1'b1;
                if (healthy_cnt == 2'b11) cap_q <= cap_q + 8'd1;
            end
        end
    end

    // ---- soft-start: duty_applied slews toward min(duty_req, duty_cap)
    logic [7:0] dapp_q = '0;
    assign duty_applied = dapp_q;
    wire [7:0] duty_target = (duty_req < cap_q) ? duty_req : cap_q;
    always_ff @(posedge okClk) begin
        if (slew_tick) begin
            if      (dapp_q < duty_target) dapp_q <= dapp_q + 1'b1;
            else if (dapp_q > duty_target) dapp_q <= dapp_q - 1'b1;
        end
        if (!heat_ok || vpanic) dapp_q <= 8'd0;   // interlock: instant off
    end

    // ---- PWM compare + gating
    logic [7:0] pwm = '0;
    always_ff @(posedge okClk) if (pwm_tick) pwm <= pwm + 1'b1;
    wire pwm_on   = (pwm < dapp_q);
    wire gate_all = pwm_on & heat_ok & ~pause;

    wire [2:0] gate = sel_onehot & {3{gate_all}};
    assign heater_any = |gate;

    // ---- three regions (instance names RA/RB/RC are pblock anchors)
    wire [2:0] alive_fast;
    heater_region #(.N_CELL(N_CELL_A), .N_DSP(N_DSP_A))
        RA (.clk_fast_raw(clk_fast_raw), .gate(gate[2]), .alive_fast(alive_fast[2]));
    heater_region #(.N_CELL(N_CELL_B), .N_DSP(N_DSP_B))
        RB (.clk_fast_raw(clk_fast_raw), .gate(gate[1]), .alive_fast(alive_fast[1]));
    heater_region #(.N_CELL(N_CELL_C), .N_DSP(N_DSP_C))
        RC (.clk_fast_raw(clk_fast_raw), .gate(gate[0]), .alive_fast(alive_fast[0]));

    // ---- alive: selected region's toggle bit, synced to okClk with a
    //      pulse-stretcher (403 MHz sampled at 100.8 MHz aliases; "changed
    //      recently" is the honest signal). CDC false-pathed in the XDC.
    wire alive_mux = |(alive_fast & sel_onehot);
    (* ASYNC_REG = "true" *) logic [1:0] alive_sync = '0;
    logic       alive_prev = 1'b0;
    logic [7:0] alive_age  = '0;
    always_ff @(posedge okClk) begin
        alive_sync <= {alive_sync[0], alive_mux};
        alive_prev <= alive_sync[1];
        if (alive_sync[1] ^ alive_prev)  alive_age <= 8'hFF;
        else if (alive_age != '0)        alive_age <= alive_age - 1'b1;
    end
    assign alive = (alive_age != '0);
endmodule

`default_nettype wire