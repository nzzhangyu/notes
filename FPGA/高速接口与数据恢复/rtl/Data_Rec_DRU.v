`timescale 1ns/1ps

// Lightweight 4x oversampling asynchronous data recovery unit.
//
// Verilog-2001 translation of the supplied Data_Rec_DRU VHDL source.
// The original "after 0.1 ns" simulation delays are intentionally omitted.
// rst is an active-high reset synchronous to both CLK4x and CLK2x. The reset
// source must meet the recovery/removal requirements of both clock domains.

module Data_Rec_DRU (
    input  wire       RxD,
    input  wire       CLK4x,
    input  wire       CLK2x,
    input  wire       rst,
    output reg  [1:0] Dout,
    output reg  [1:0] VO,
    output reg  [3:0] RawData_o
);

    wire Q1;
    wire Q2;

    reg Q1F;
    reg Q2F;
    reg Q1R;
    reg Q2R;

    reg [3:0] RxRawData;
    reg [3:0] II;
    reg [3:0] ID;
    reg [3:0] IDD;
    reg       I3DD;
    reg [3:0] E4;
    reg [1:0] S;
    reg [1:0] DVE;
    reg [1:0] DO;
    reg [1:0] DV;

    wire [1:0] cDVE;
    wire [1:0] cDV;

    // 7 Series double-data-rate input register.
    IDDR #(
        .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
        .INIT_Q1      (1'b0),
        .INIT_Q2      (1'b0),
        .SRTYPE       ("SYNC")
    ) IDDR_inst (
        .Q1(Q1),
        .Q2(Q2),
        .C (CLK4x),
        .CE(1'b1),
        .D (RxD),
        .R (rst),
        .S (1'b0)
    );

    // For an UltraScale+ implementation, replace the IDDR instance above
    // with an IDDRE1 configured for SAME_EDGE_PIPELINED operation. The exact
    // C/CB clock connections must follow the target device documentation.

    // Capture two consecutive IDDR output pairs.
    always @(posedge CLK4x) begin
        if (rst) begin
            Q1F <= 1'b0;
            Q2F <= 1'b0;
            Q1R <= 1'b0;
            Q2R <= 1'b0;
        end else begin
            Q1F <= Q1;
            Q2F <= Q2;
            Q1R <= Q1F;
            Q2R <= Q2F;
        end
    end

    // RawData_o[3] is the earliest sample and RawData_o[0] is the latest.
    always @(posedge CLK2x) begin
        if (rst)
            RxRawData <= 4'b0000;
        else
            RxRawData <= {Q1R, Q2R, Q1F, Q2F};
    end

    always @(posedge CLK2x) begin
        if (rst)
            II <= 4'b0000;
        else
            II <= RxRawData;
    end

    // Edge detection includes the boundary between adjacent raw sample words.
    always @(posedge CLK2x) begin
        if (rst) begin
            ID   <= 4'b0000;
            IDD  <= 4'b0000;
            E4   <= 4'b0000;
            I3DD <= 1'b0;
        end else begin
            ID   <= II;
            IDD  <= ID;
            E4   <= II ^ {ID[0], II[3:1]};
            I3DD <= ID[3];
        end
    end

    assign cDVE[0] = (S == 2'b10) && !E4[3] && E4[2];
    assign cDVE[1] = (S == 2'b00) && !E4[3] && E4[0];

    assign cDV[0] = ~(DVE[0] ^ DVE[1]);
    assign cDV[1] = DVE[0];

    // Four-state phase tracker, selected sample, and bit-skip control.
    // Nonblocking assignments preserve the old-state sampling behavior of
    // the original clocked VHDL process.
    always @(posedge CLK2x) begin
        if (rst) begin
            S   <= 2'b00;
            DVE <= 2'b00;
            DV  <= 2'b00;
            DO  <= 2'b00;
        end else begin
            case (S)
                2'b00: begin
                    if (E4[0])
                        S <= 2'b10;
                    else if (E4[3])
                        S <= 2'b01;
                end

                2'b01: begin
                    if (E4[1])
                        S <= 2'b00;
                    else if (E4[0])
                        S <= 2'b11;
                end

                2'b11: begin
                    if (E4[2])
                        S <= 2'b01;
                    else if (E4[1])
                        S <= 2'b10;
                end

                2'b10: begin
                    if (E4[3])
                        S <= 2'b11;
                    else if (E4[2])
                        S <= 2'b00;
                end

                default: begin
                    // Hold state, matching "when others => null".
                end
            endcase

            DVE <= cDVE;
            DV  <= cDV;

            case (S)
                2'b00:   DO <= {I3DD, IDD[0]};
                2'b01:   DO <= {I3DD, IDD[1]};
                2'b11:   DO <= {I3DD, IDD[2]};
                2'b10:   DO <= {I3DD, IDD[3]};
                default: begin
                    // Hold output, matching "when others => null".
                end
            endcase
        end
    end

    // Registered user and debug outputs.
    always @(posedge CLK2x) begin
        if (rst) begin
            Dout      <= 2'b00;
            VO        <= 2'b00;
            RawData_o <= 4'b0000;
        end else begin
            Dout      <= DO;
            VO        <= DV;
            RawData_o <= RxRawData;
        end
    end

endmodule
