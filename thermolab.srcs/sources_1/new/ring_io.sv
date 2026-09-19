`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// ring_io.sv -- the temperature sensor that actually works.
//
// Ring oscillator threaded through N_PADS IOBUF *pad loopbacks*: each stage
// drives its own pad through the output buffer and reads the same pad back
// through the input buffer (T=0, input buffer always listens). No external
// wiring is needed; the pins can float.
//
// Why this has a strong temperature coefficient when LUT rings do not:
//   * Core (VCCINT = 1.0 V) 28 nm transistors sit near the zero-temperature-
//     coefficient (ZTC) point: mobility loss (slower with T) and Vth reduction
//     (faster with T) nearly cancel -> LUT ring TC ~ +/-0.01-0.03 %/degC with
//     process-dependent sign. That is the wall the naive design hits.
//   * I/O buffers are thick-oxide transistors running from VCCO = 3.3 V,
//     several volts above their ZTC point. There the Vth term is negligible
//     and mobility (~T^-1.5) dominates, so drive current falls and delay
//     RISES monotonically with temperature, typically ~ +0.1..0.3 %/degC.
//     The pad RC (driver on-resistance x pad/package capacitance) adds a
//     further positive term. Process spread moves the magnitude, not the
//     sign: every board reads the same direction.
//
// Loop structure (all cells DONT_TOUCH; loop blessed in XDC):
//   gate LUT2 (inverting, AND with enable) -> IOBUF0 -> inv LUT1 -> IOBUF1
//   -> ... -> IOBUF[N-1] -> back to gate.  Inversions = N_PADS (odd) => osc.
//   enable=0 forces the loop to a quiescent 0.
//
// Expected frequency: ~6-10 ns per pad loop -> ~10-20 MHz for N_PADS=5.
//=============================================================================
module ring_io #(
    parameter integer N_PADS = 5      // must be odd
)(
    inout  wire [N_PADS-1:0] pad,
    input  wire              enable,  // async, host-controlled
    output wire              ring_out
);

    wire [N_PADS-1:0] from_pad;   // IOBUF.O  (read back from pad)
    wire [N_PADS-1:0] to_pad;     // IOBUF.I  (drive to pad)

    genvar i;
    generate
        for (i = 0; i < N_PADS; i = i + 1) begin : g_pad
            (* DONT_TOUCH = "TRUE" *)
            IOBUF u_iob (
                .IO(pad[i]),
                .I (to_pad[i]),
                .O (from_pad[i]),
                .T (1'b0)          // output always enabled; input always reads pad
            );
        end
    endgenerate

    // stage 0: inverting gate, O = ~I0 & I1  (INIT 4'h4)
    (* DONT_TOUCH = "TRUE" *)
    LUT2 #(.INIT(4'h4)) u_gate (
        .I0(from_pad[N_PADS-1]),
        .I1(enable),
        .O (to_pad[0])
    );

    // stages 1..N-1: plain inverters
    generate
        for (i = 1; i < N_PADS; i = i + 1) begin : g_inv
            (* DONT_TOUCH = "TRUE" *)
            LUT1 #(.INIT(2'b01)) u_inv (
                .I0(from_pad[i-1]),
                .O (to_pad[i])
            );
        end
    endgenerate

    assign ring_out = from_pad[0];

endmodule
`default_nettype wire