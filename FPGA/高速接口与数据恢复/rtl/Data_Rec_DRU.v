`timescale 1ns/1ps

// 4x asynchronous oversampling data recovery
// Verilog-2001
// Active-high synchronous reset

module Data_Rec_DRU (
    input  wire       RxD,
    input  wire       CLK4x,
    input  wire       CLK2x,
    input  wire       rst,
    output reg  [1:0] Dout,
    output reg  [1:0] VO,
    output reg  [3:0] RawData_o
);

    // IDDR dual-edge outputs
    wire Q1;
    wire Q2;

    // Two consecutive rising/falling sample pairs
    reg Q1R;
    reg Q1F;
    reg Q2R;
    reg Q2F;

    // Four-sample pipeline
    reg [3:0] dout_raw;
    reg [3:0] dout_raw_d1;
    reg [3:0] dout_raw_d2;
    reg [3:0] dout_raw_d3;
    reg       dout_raw_msb_d3;

    // Edge information and phase state
    reg [3:0] E4;
    reg [1:0] EQ;
    reg [1:0] EQ_next;

    // Bit-skip and recovered output
    reg [1:0] bit_skip_event;
    reg [1:0] dout;
    reg [1:0] dout_valid;

    wire [1:0] bit_skip_event_next;
    wire [1:0] dout_valid_next;

    // 7 Series IDDR input sampling
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

    // UltraScale+ migration: replace with IDDRE1

    // Two consecutive DDR sample pairs
    // Q1: earlier pair; Q2: later pair
    // R: rising-edge sample; F: falling-edge sample
    always @(posedge CLK4x) begin
        if (rst) begin
            Q1R <= 1'b0;
            Q1F <= 1'b0;
            Q2R <= 1'b0;
            Q2F <= 1'b0;
        end 
        else begin
            Q2R <= Q1;
            Q2F <= Q2;
            Q1R <= Q2R;
            Q1F <= Q2F;
        end
    end

    // Four-sample packing: earliest sample in MSB
    always @(posedge CLK2x) begin
        if (rst)
            dout_raw <= 4'b0000;
        else
            dout_raw <= {Q1R, Q1F, Q2R, Q2F};
    end

    // Raw-sample pipeline stage
    always @(posedge CLK2x) begin
        if (rst)
            dout_raw_d1 <= 4'b0000;
        else
            dout_raw_d1 <= dout_raw;
    end

    // Cross-word edge detection and data-select pipeline
    always @(posedge CLK2x) begin
        if (rst) begin
            dout_raw_d2     <= 4'b0000;
            dout_raw_d3     <= 4'b0000;
            E4              <= 4'b0000;
            dout_raw_msb_d3 <= 1'b0;
        end 
        else begin
            dout_raw_d2     <= dout_raw_d1;
            dout_raw_d3     <= dout_raw_d2;
            E4              <= dout_raw_d1
                             ^ {dout_raw_d2[0], dout_raw_d1[3:1]};
            dout_raw_msb_d3 <= dout_raw_d2[3];
        end
    end

    // Positive bit skip: 2 valid bits
    // Negative bit skip: 0 valid bits
    assign bit_skip_event_next[0] = (EQ == 2'b10) && !E4[3] && E4[2];
    assign bit_skip_event_next[1] = (EQ == 2'b00) && !E4[3] && E4[0];

    // Valid-bit count: 00/01/10 means 0/1/2 bits
    assign dout_valid_next[0] = ~(bit_skip_event[0] ^ bit_skip_event[1]);
    assign dout_valid_next[1] = bit_skip_event[0];

    // State register
    always @(posedge CLK2x) begin
        if (rst)
            EQ <= 2'b00;
        else
            EQ <= EQ_next;
    end

    // Next-state logic
    always @(*) begin
        EQ_next = EQ;

        case (EQ)
            2'b00: begin
                if (E4[0])
                    EQ_next = 2'b10;
                else if (E4[3])
                    EQ_next = 2'b01;
            end

            2'b01: begin
                if (E4[1])
                    EQ_next = 2'b00;
                else if (E4[0])
                    EQ_next = 2'b11;
            end

            2'b11: begin
                if (E4[2])
                    EQ_next = 2'b01;
                else if (E4[1])
                    EQ_next = 2'b10;
            end

            2'b10: begin
                if (E4[3])
                    EQ_next = 2'b11;
                else if (E4[2])
                    EQ_next = 2'b00;
            end

            default: begin
                EQ_next = 2'b00;
            end
        endcase
    end

    // Registered output logic
    always @(posedge CLK2x) begin
        if (rst) begin
            bit_skip_event  <= 2'b00;
            dout_valid      <= 2'b00;
            dout            <= 2'b00;
        end else begin
            bit_skip_event <= bit_skip_event_next;
            dout_valid     <= dout_valid_next;

            case (EQ)
                2'b00: dout <= {dout_raw_msb_d3, dout_raw_d3[0]};
                2'b01: dout <= {dout_raw_msb_d3, dout_raw_d3[1]};
                2'b11: dout <= {dout_raw_msb_d3, dout_raw_d3[2]};
                2'b10: dout <= {dout_raw_msb_d3, dout_raw_d3[3]};
                default: begin
                    // Hold output
                end
            endcase
        end
    end

    // Interface output registers
    always @(posedge CLK2x) begin
        if (rst) begin
            Dout      <= 2'b00;
            VO        <= 2'b00;
            RawData_o <= 4'b0000;
        end else begin
            Dout      <= dout;
            VO        <= dout_valid;
            RawData_o <= dout_raw;
        end
    end

endmodule
