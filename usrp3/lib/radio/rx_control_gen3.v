//
// Copyright 2015 Ettus Research
//
// Converts strobed sample data from radio frontend to the AXI-Stream bus
// Outputs an error packet if an overrun, late timed command, or empty command fifo error occurs.

// HALT brings RX to an idle state as quickly as possible if RX is running
// without running the risk of leaving a packet fragment in downstream FIFO's.
// HALT also flushes all remaining pending commands in the commmand FIFO.

module rx_control_gen3 #(
  parameter SR_RX_CTRL_COMMAND = 0,     // Command FIFO
  parameter SR_RX_CTRL_TIME_HI = 1,     // Command execute time (high word)
  parameter SR_RX_CTRL_TIME_LO = 2,     // Command execute time (low word)
  parameter SR_RX_CTRL_HALT = 3,        // Halt command -> return to idle state
  parameter SR_RX_CTRL_MAXLEN = 4       // Packet length
)(
  input clk, input reset, input clear,
  input [63:0] vita_time, input [31:0] sid, input [31:0] resp_sid,
  input set_stb, input [7:0] set_addr, input [31:0] set_data,
  // Data packets
  output [31:0] rx_tdata, output rx_tlast, output rx_tvalid, input rx_tready, output [127:0] rx_tuser,
  // Error packets
  output reg [63:0] resp_tdata, output reg [127:0] resp_tuser, output reg resp_tlast, output reg resp_tvalid, input resp_tready,
  // From radio frontend
  output run, input [31:0] sample, input strobe
);

  wire [31:0] command_i;
  wire [63:0] time_i;
  wire store_command;

  wire send_imm, chain, reload, stop;
  wire [27:0] numlines;
  wire [63:0] rcvtime;

  wire now, early, late;
  wire command_valid;
  reg command_ready;

  reg chain_sav, reload_sav;
  reg clear_halt;
  reg halt;
  wire set_halt;
  wire [15:0] maxlen;
  wire eob;
  reg [63:0] start_time;

  setting_reg #(.my_addr(SR_RX_CTRL_COMMAND)) sr_cmd (
    .clk(clk),.rst(reset),.strobe(set_stb),.addr(set_addr),
    .in(set_data),.out(command_i),.changed());

  setting_reg #(.my_addr(SR_RX_CTRL_TIME_HI)) sr_time_h (
    .clk(clk),.rst(reset),.strobe(set_stb),.addr(set_addr),
    .in(set_data),.out(time_i[63:32]),.changed());

  setting_reg #(.my_addr(SR_RX_CTRL_TIME_LO)) sr_time_l (
    .clk(clk),.rst(reset),.strobe(set_stb),.addr(set_addr),
    .in(set_data),.out(time_i[31:0]),.changed(store_command));

  setting_reg #(.my_addr(SR_RX_CTRL_HALT)) sr_rx_halt (
    .clk(clk),.rst(reset),.strobe(set_stb),.addr(set_addr),
    .in(set_data),.out(),.changed(set_halt));

  setting_reg #(.my_addr(SR_RX_CTRL_MAXLEN), .width(16)) sr_maxlen (
    .clk(clk),.rst(reset),.strobe(set_stb),.addr(set_addr),
    .in(set_data),.out(maxlen),.changed());

  always @(posedge clk)
    if (reset | clear | clear_halt)
      halt <= 1'b0;
    else
      halt <= set_halt;

  axi_fifo_short #(.WIDTH(96)) commandfifo (
    .clk(clk),.reset(reset),.clear(clear | clear_halt),
    .i_tdata({command_i,time_i}), .i_tvalid(store_command), .i_tready(),
    .o_tdata({send_imm,chain,reload,stop,numlines,rcvtime}),
    .o_tvalid(command_valid), .o_tready(command_ready),
    .occupied(), .space() );

  time_compare time_compare (
    .clk(clk), .reset(reset),
    .time_now(vita_time), .trigger_time(rcvtime), .now(now), .early(early), .late(late), .too_early());

  // State machine states
  localparam IBS_IDLE               = 0;
  localparam IBS_RUNNING            = 1;
  localparam IBS_ERR_WAIT_FOR_READY = 2;

  // Error codes
  localparam ERR_OVERRUN      = {32'd8,32'd0};
  localparam ERR_BROKENCHAIN  = {32'd4,32'd0};
  localparam ERR_LATECMD      = {32'd2,32'd0};

  wire [127:0] error_header = {2'b11, 1'b1, 1'b1, 12'd0 /* don't care */, 16'd0 /* don't care */, resp_sid, vita_time};

  reg [2:0] ibs_state;
  reg [27:0] lines_left, repeat_lines;
  reg [15:0] lines_left_pkt;

  always @(posedge clk) begin
    if (reset | clear) begin
      ibs_state <= IBS_IDLE;
      lines_left <= 'd0;
      lines_left_pkt <= 'd0;
      repeat_lines <= 'd0;
      start_time <= 'd0;
      chain_sav <= 1'b0;
      reload_sav <= 1'b0;
      clear_halt <= 1'b0;
      resp_tdata <= 'd0;
      resp_tlast <= 1'b0;
      resp_tvalid <= 1'b0;
      resp_tuser <= 'd0;
    end else begin
      case (ibs_state)
        IBS_IDLE : begin
          clear_halt <= 1'b0; // Incase we got here through a HALT.
          if (command_valid) begin
            // There is a valid command to pop from FIFO.
            if (stop) begin
              // Stop bit set in this command, go idle.
              ibs_state <= IBS_IDLE;
            end else if (late & ~send_imm) begin
              // Got this command later than its execution time.
              resp_tvalid <= 1'b1;
              resp_tlast <= 1'b1;
              resp_tuser <= error_header;
              resp_tdata <= ERR_LATECMD;
              ibs_state <= IBS_ERR_WAIT_FOR_READY;
            end else if (now | send_imm) begin
              // Either its time to run this command or it should run immediately without a time.
              ibs_state <= IBS_RUNNING;
              lines_left <= numlines;
              repeat_lines <= numlines;
              chain_sav <= chain;
              reload_sav <= reload;
              lines_left_pkt <= maxlen;
            end
          end
        end

        IBS_RUNNING : begin
          if (strobe) begin
            if (~rx_tready) begin // Framing FIFO is full and we have just overrun.
              resp_tvalid <= 1'b1;
              resp_tlast <= 1'b1;
              resp_tuser <= error_header;
              resp_tdata <= ERR_OVERRUN;
              ibs_state <= IBS_ERR_WAIT_FOR_READY;
            end else begin
              if (lines_left_pkt == 1) begin
                lines_left_pkt <= maxlen;
              end else begin
                lines_left_pkt <= lines_left_pkt - 1;
              end
              if (lines_left_pkt == maxlen) begin
                start_time <= vita_time;
              end
              if (lines_left == 1) begin
                if (halt) begin // Provide Halt mechanism used to bring RX into known IDLE state at re-initialization.
                  ibs_state <= IBS_IDLE;
                  clear_halt <= 1'b1;
                end else if (chain_sav) begin // If chain_sav is true then execute the next command now this one finished.
                  if (command_valid) begin
                    lines_left <= numlines;
                    repeat_lines <= numlines;
                    chain_sav <= chain;
                    reload_sav <= reload;
                    if (stop) begin // If the new command includes stop then go idle.
                      ibs_state <= IBS_IDLE;
                    end
                  end else if (reload_sav) begin // There is no new command to pop from FIFO so re-run previous command.
                    lines_left <= repeat_lines;
                  end else begin // Chain has been broken, no commands left in FIFO and reload not set.
                    resp_tvalid <= 1'b1;
                    resp_tlast <= 1'b1;
                    resp_tuser <= error_header;
                    resp_tdata <= ERR_BROKENCHAIN;
                    ibs_state <= IBS_ERR_WAIT_FOR_READY;
                  end
                end else begin // Chain is not true, so don't look for new command, instead go idle.
                  ibs_state <= IBS_IDLE;
                end
              end else begin // Still counting down lines in current command.
                lines_left <= lines_left - 28'd1;
              end
            end
          end
        end

        // Error occured from idle state, wait for error packet to be consumed
        IBS_ERR_WAIT_FOR_READY : begin
          if (resp_tready) begin
            resp_tvalid <= 1'b0;
            resp_tlast <= 1'b0;
            ibs_state <= IBS_IDLE;
          end
        end

        default : ibs_state <= IBS_IDLE;
      endcase
    end
  end

  assign run = (ibs_state == IBS_RUNNING);

  always @* begin
    case(ibs_state)
      IBS_IDLE    : command_ready <= stop | late | now | send_imm;
      IBS_RUNNING : command_ready <= strobe & (lines_left == 1) & chain_sav;
      default     : command_ready <= 1'b0;
    endcase // case (ibs_state)
  end

  assign eob = (strobe && (lines_left == 1) && ( !chain_sav || (command_valid && stop) || (!command_valid && !reload_sav) || halt));

  assign rx_tdata = sample;
  assign rx_tlast = eob | (lines_left_pkt == 1);
  assign rx_tvalid = run & strobe;
  assign rx_tuser = { 3'b001 /*Data w/Time*/, eob, 12'h0 /*seqnum ignored*/, 16'h0 /*len ignored */, sid, start_time };

endmodule // new_rx_control