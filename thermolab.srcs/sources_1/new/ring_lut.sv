`timescale 1ns / 1ps
`default_nettype none
//=============================================================================
// ring_lut.sv -- CONTROL channel: classic LUT-inverter ring in the 1.0 V core
// domain. Deliberately kept even though (because!) its temperature coefficient
// is ~zero on 28 nm at nominal VCCINT: it shares the identical counting
// machinery with ring_io, so a flat line here next to a steep line there
// proves the effect is physics, not measurement artifact.
//
// Inversions = 1 (gate) + N_INV = 33 (odd) => oscillates, ~15-30 MHz.
//=============================================================================
module ring_lut #(
    parameter integer N_INV = 32      // must be even (gate adds the odd inversion)
)(
    input  wire enable,
    output wire ring_out
);

    wire [N_INV:0] c;

    // inverting gate closes the loop: O = ~I0 & I1
    (* DONT_TOUCH = "TRUE" *)
    LUT2 #(.INIT(4'h4)) u_gate (
        .I0(c[N_INV]),
        .I1(enable),
        .O (c[0])
    );

    genvar i;
    generate
        for (i = 0; i < N_INV; i = i + 1) begin : g_inv
            (* DONT_TOUCH = "TRUE" *)
            LUT1 #(.INIT(2'b01)) u_inv (
                .I0(c[i]),
                .O (c[i+1])
            );
        end
    endgenerate

    assign ring_out = c[0];

endmodule
`default_nettype wire