`timescale 1ns/1ps

module tb_Data_Rec_DRU;

    localparam integer TX_BITS       = 10000;
    localparam integer MAX_RX_BITS   = 14000;
    localparam integer ALIGN_WINDOW  = 256;
    localparam integer ALIGN_COMPARE = 2048;

    reg        RxD;
    reg        CLK4x;
    reg        CLK2x;
    reg        rst;
    wire [1:0] Dout;
    wire [1:0] VO;
    wire [3:0] RawData_o;

    reg tx_bits [0:TX_BITS-1];
    reg rx_bits [0:MAX_RX_BITS-1];

    integer rx_count;
    integer positive_skip_count;
    integer negative_skip_count;
    integer assertion_errors;
    integer total_scenarios;
    integer failed_scenarios;
    integer scenario_active;
    integer monitor_initialized;
    reg [1:0] previous_EQ;
    reg [3:0] previous_E4;

    Data_Rec_DRU dut (
        .RxD      (RxD),
        .CLK4x    (CLK4x),
        .CLK2x    (CLK2x),
        .rst      (rst),
        .Dout     (Dout),
        .VO       (VO),
        .RawData_o(RawData_o)
    );

    initial begin
        CLK4x = 1'b0;
        forever #1.25 CLK4x = ~CLK4x;
    end

    initial begin
        CLK2x = 1'b0;
        forever #2.50 CLK2x = ~CLK2x;
    end

    function automatic [1:0] expected_next_EQ;
        input [1:0] current_EQ;
        input [3:0] edge_info;
        begin
            expected_next_EQ = current_EQ;
            case (current_EQ)
                2'b00: begin
                    if (edge_info[0])
                        expected_next_EQ = 2'b10;
                    else if (edge_info[3])
                        expected_next_EQ = 2'b01;
                end

                2'b01: begin
                    if (edge_info[1])
                        expected_next_EQ = 2'b00;
                    else if (edge_info[0])
                        expected_next_EQ = 2'b11;
                end

                2'b11: begin
                    if (edge_info[2])
                        expected_next_EQ = 2'b01;
                    else if (edge_info[1])
                        expected_next_EQ = 2'b10;
                end

                2'b10: begin
                    if (edge_info[3])
                        expected_next_EQ = 2'b11;
                    else if (edge_info[2])
                        expected_next_EQ = 2'b00;
                end

                default: expected_next_EQ = 2'b00;
            endcase
        end
    endfunction

    task automatic build_tx_stream;
        integer i;
        reg [6:0] prbs7;
        reg feedback;
        begin
            prbs7 = 7'h5d;

            for (i = 0; i < TX_BITS; i = i + 1) begin
                if (i < 256) begin
                    tx_bits[i] = i[0];
                end
                else begin
                    tx_bits[i] = prbs7[6];
                    feedback = prbs7[6] ^ prbs7[5];
                    prbs7 = {prbs7[5:0], feedback};
                end
            end

            for (i = 3000; i < 3032; i = i + 1)
                tx_bits[i] = 1'b0;

            for (i = 6000; i < 6032; i = i + 1)
                tx_bits[i] = 1'b1;
        end
    endtask

    task automatic analyze_stream;
        input integer scenario_number;
        input real data_rate_mbps;
        input real phase_ns;
        input integer expect_positive_skip;
        input integer expect_negative_skip;
        integer tx_offset;
        integer rx_offset;
        integer i;
        integer compare_count;
        integer errors;
        integer best_errors;
        integer best_tx_offset;
        integer best_rx_offset;
        integer full_compare_count;
        integer full_errors;
        integer scenario_failed;
        begin
            best_errors = ALIGN_COMPARE + 1;
            best_tx_offset = -1;
            best_rx_offset = -1;

            for (tx_offset = 0;
                 tx_offset < ALIGN_WINDOW;
                 tx_offset = tx_offset + 1) begin
                for (rx_offset = 0;
                     rx_offset < ALIGN_WINDOW;
                     rx_offset = rx_offset + 1) begin
                    compare_count = ALIGN_COMPARE;

                    if ((tx_offset + compare_count) > TX_BITS)
                        compare_count = TX_BITS - tx_offset;

                    if ((rx_offset + compare_count) > rx_count)
                        compare_count = rx_count - rx_offset;

                    if (compare_count > 0) begin
                        errors = 0;
                        for (i = 0; i < compare_count; i = i + 1)
                            if (tx_bits[tx_offset+i] !==
                                rx_bits[rx_offset+i])
                                errors = errors + 1;

                        if (errors < best_errors) begin
                            best_errors = errors;
                            best_tx_offset = tx_offset;
                            best_rx_offset = rx_offset;
                        end
                    end
                end
            end

            scenario_failed = 0;
            full_errors = -1;
            full_compare_count = 0;

            if ((best_tx_offset < 0) || (best_rx_offset < 0)) begin
                scenario_failed = 1;
            end
            else begin
                full_compare_count = TX_BITS - best_tx_offset;

                if ((rx_count - best_rx_offset) < full_compare_count)
                    full_compare_count = rx_count - best_rx_offset;

                full_errors = 0;
                for (i = 0; i < full_compare_count; i = i + 1)
                    if (tx_bits[best_tx_offset+i] !==
                        rx_bits[best_rx_offset+i])
                        full_errors = full_errors + 1;

                if ((best_errors != 0) || (full_errors != 0))
                    scenario_failed = 1;
            end

            if (assertion_errors != 0)
                scenario_failed = 1;

            if (expect_positive_skip && (positive_skip_count == 0))
                scenario_failed = 1;

            if (expect_negative_skip && (negative_skip_count == 0))
                scenario_failed = 1;

            if (scenario_failed)
                failed_scenarios = failed_scenarios + 1;

            $display(
                "SCENARIO %0d rate=%0.3fMb/s phase=%0.4fns tx=%0d rx=%0d align_tx=%0d align_rx=%0d compared=%0d errors=%0d pos_skip=%0d neg_skip=%0d assertions=%0d result=%s",
                scenario_number,
                data_rate_mbps,
                phase_ns,
                TX_BITS,
                rx_count,
                best_tx_offset,
                best_rx_offset,
                full_compare_count,
                full_errors,
                positive_skip_count,
                negative_skip_count,
                assertion_errors,
                scenario_failed ? "FAIL" : "PASS"
            );
        end
    endtask

    task automatic run_scenario;
        input integer scenario_number;
        input real data_rate_mbps;
        input real phase_ns;
        input integer expect_positive_skip;
        input integer expect_negative_skip;
        real ui_ns;
        integer i;
        begin
            ui_ns = 1000.0 / data_rate_mbps;
            total_scenarios = total_scenarios + 1;
            scenario_active = 0;
            rst = 1'b1;
            RxD = 1'b0;
            rx_count = 0;
            positive_skip_count = 0;
            negative_skip_count = 0;
            assertion_errors = 0;
            monitor_initialized = 0;
            build_tx_stream();

            repeat (12) @(posedge CLK2x);
            @(negedge CLK2x);
            rst = 1'b0;
            #(phase_ns);
            scenario_active = 1;

            for (i = 0; i < TX_BITS; i = i + 1) begin
                RxD = tx_bits[i];
                #(ui_ns);
            end

            repeat (80) @(posedge CLK2x);
            @(negedge CLK2x);
            scenario_active = 0;
            analyze_stream(
                scenario_number,
                data_rate_mbps,
                phase_ns,
                expect_positive_skip,
                expect_negative_skip
            );

            rst = 1'b1;
            RxD = 1'b0;
            repeat (4) @(posedge CLK2x);
        end
    endtask

    always @(negedge CLK2x) begin
        if (scenario_active && !rst) begin
            if ($isunknown({
                Dout,
                VO,
                RawData_o,
                dut.EQ,
                dut.E4,
                dut.bit_skip_event
            })) begin
                assertion_errors = assertion_errors + 1;
                $display("ASSERT unknown value at %0t", $time);
            end

            if ((VO !== 2'b00) &&
                (VO !== 2'b01) &&
                (VO !== 2'b10)) begin
                assertion_errors = assertion_errors + 1;
                $display("ASSERT illegal VO=%b at %0t", VO, $time);
            end

            if (dut.bit_skip_event == 2'b11) begin
                assertion_errors = assertion_errors + 1;
                $display("ASSERT simultaneous bit skips at %0t", $time);
            end

            if (monitor_initialized) begin
                if (dut.EQ !== expected_next_EQ(previous_EQ, previous_E4)) begin
                    assertion_errors = assertion_errors + 1;
                    $display(
                        "ASSERT EQ transition prev=%b E4=%b actual=%b expected=%b at %0t",
                        previous_EQ,
                        previous_E4,
                        dut.EQ,
                        expected_next_EQ(previous_EQ, previous_E4),
                        $time
                    );
                end
            end

            previous_EQ = dut.EQ;
            previous_E4 = dut.E4;
            monitor_initialized = 1;

            if (dut.bit_skip_event[0])
                positive_skip_count = positive_skip_count + 1;

            if (dut.bit_skip_event[1])
                negative_skip_count = negative_skip_count + 1;

            case (VO)
                2'b00: begin
                end

                2'b01: begin
                    if (rx_count < MAX_RX_BITS) begin
                        rx_bits[rx_count] = Dout[0];
                        rx_count = rx_count + 1;
                    end
                end

                2'b10: begin
                    if ((rx_count + 1) < MAX_RX_BITS) begin
                        rx_bits[rx_count] = Dout[0];
                        rx_bits[rx_count+1] = Dout[1];
                        rx_count = rx_count + 2;
                    end
                end
            endcase
        end
    end

    initial begin
        RxD = 1'b0;
        rst = 1'b1;
        scenario_active = 0;
        total_scenarios = 0;
        failed_scenarios = 0;

        run_scenario(1, 200.0, 0.3125, 0, 0);
        run_scenario(2, 200.0, 0.9375, 0, 0);
        run_scenario(3, 200.0, 1.5625, 0, 0);
        run_scenario(4, 200.0, 2.1875, 0, 0);
        run_scenario(5, 200.0, 2.8125, 0, 0);
        run_scenario(6, 200.0, 3.4375, 0, 0);
        run_scenario(7, 200.0, 4.0625, 0, 0);
        run_scenario(8, 200.0, 4.6875, 0, 0);
        run_scenario(9, 202.0, 1.5625, 1, 0);
        run_scenario(10, 198.0, 1.5625, 0, 1);

        $display(
            "SUMMARY scenarios=%0d failed=%0d result=%s",
            total_scenarios,
            failed_scenarios,
            failed_scenarios ? "FAIL" : "PASS"
        );

        if (failed_scenarios)
            $fatal(1, "Data_Rec_DRU functional verification failed");

        $finish;
    end

endmodule
