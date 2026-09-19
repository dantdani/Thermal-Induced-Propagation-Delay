`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// freq_counter.sv -- counts ring cycles inside a hardware-timed window.
//
// The ring output (via BUFG) clocks a 32-bit counter. The okClk-domain window
// is double-synchronized into the ring domain; the counter clears on the
// window's rising edge and counts while it is high. Window-edge sync
// uncertainty is +/-1-2 ring cycles out of ~10^5-10^6: <= ~10 ppm, far below
// the thermal signal.
//
// Capture: after the window closes, top level waits ~5 us (counter is then
// static), then pulses cap_strobe in the okClk domain to latch the value.
// The cross-domain sample is quasi-static by construction -> safe; the two
// domains are declared asynchronous in the XDC.
//=============================================================================
module freq_counter (
    input  wire        clk_ring,
    input  wire        okClk,
    input  wire        window_ok,    // okClk domain
    input  wire        cap_strobe,   // okClk domain, >= 5 us after window falls
    output reg  [31:0] value = 32'd0
);

    (* ASYNC_REG = "TRUE" *) reg [1:0] wsync = 2'd0;
    reg        wprev = 1'b0;
    reg [31:0] cnt   = 32'd0;

    always @(posedge clk_ring) begin
        wsync <= {wsync[0], window_ok};
        wprev <= wsync[1];
        if (wsync[1] && !wprev)
            cnt <= 32'd1;             // first counted cycle of the window
        else if (wsync[1])
            cnt <= cnt + 32'd1;
    end

    always @(posedge okClk)
        if (cap_strobe)
            value <= cnt;             // quasi-static at this moment

endmodule
`default_nettype wire