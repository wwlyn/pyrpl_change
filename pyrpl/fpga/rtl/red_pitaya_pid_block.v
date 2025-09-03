/**
 * $Id: red_pitaya_pid_block.v 961 2014-01-21 11:40:39Z matej.oblak $
 *
 * @brief Red Pitaya PID controller.
 *
 * @Author Matej Oblak
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in Verilog hardware description language (HDL).
 * Please visit http://en.wikipedia.org/wiki/Verilog
 * for more details on the language used herein.
 */
/*
###############################################################################
#    pyrpl - DSP servo controller for quantum optics with the RedPitaya
#    Copyright (C) 2014-2016  Leonhard Neuhaus  (neuhaus@spectro.jussieu.fr)
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
############################################################################### 
*/


/*
 * GENERAL DESCRIPTION:
 *
 * Proportional-integral-derivative (PID) controller.
 *
 *
 *        /---\         /---\      /-----------\
 *   IN --| - |----+--> | P | ---> | SUM & SAT | ---> OUT
 *        \---/    |    \---/      \-----------/
 *          ^      |                   ^  ^
 *          |      |    /---\          |  |
 *   set ----      +--> | I | ---------   |
 *   point         |    \---/             |
 *                 |                      |
 *                 |    /---\             |
 *                 ---> | D | ------------
 *                      \---/
 *
 *
 * Proportional-integral-derivative (PID) controller is made from three parts. 
 *
 * Error which is difference between set point and input signal is driven into
 * propotional, integral and derivative part. Each calculates its own value which
 * is then summed and saturated before given to output.
 *
 * Integral part has also separate input to reset integrator value to 0.
 * 
 */

module red_pitaya_pid_block #(
   //parameters for gain control (binary points and total bitwidth)
   parameter     PSR = 12         ,
   parameter     ISR = 32         ,//official redpitaya: 18
   parameter     DSR = 10         ,
   parameter     GAINBITS = 30    ,
   parameter     DERIVATIVE = 0   , //disables differential gain if 0
   
   //parameters for input pre-filter
   parameter     FILTERSTAGES = 3 ,
   parameter     FILTERSHIFTBITS = 5,
   parameter     FILTERMINBW = 10,
   
   //enable arbitrary output saturation or not
   parameter     ARBITRARY_SATURATION = 1
)
(
   // data
   input                 clk_i           ,  // clock
   input                 rstn_i          ,  // reset - active low
   input                 paused_i          ,  // synchronization/pausing input
   input signed     [ 14-1: 0] dat_i           ,  // input data
   output signed    [ 14-1: 0] dat_o           ,  // output data
   input signed     [ 14-1: 0] diff_dat_i      ,  // input data for differential mode
   output signed    [ 14-1: 0] diff_dat_o      ,  // input data for differential mode
   input                 setpoint_trig_i     ,

   // communication with PS
   input      [ 16-1: 0] addr,
   input                 wen,
   input                 ren,
   output reg   		 ack,
   output reg [ 32-1: 0] rdata,
   input      [ 32-1: 0] wdata
);

//-----------------------------
// Setpoint sequence with robust TTL edge detection
reg [3:0] setpoint_array_write_index;
reg use_setpoint_sequence; // 0=normal mode，1=sequence mode

parameter SETPOINT_LEN = 16;
parameter SETPOINT_WIDTH = 14;
reg signed [SETPOINT_WIDTH-1:0] setpoint_array [0:SETPOINT_LEN-1];
reg [4-1:0] setpoint_index;
reg sequence_wrap_flag;

// Synchronize TTL input to FPGA clock to avoid metastability
reg setpoint_trig_sync0, setpoint_trig_sync1;
reg setpoint_trig_sync_d;

wire signed [SETPOINT_WIDTH-1:0] setpoint;
assign setpoint = setpoint_array[setpoint_index];

// Detect rising edge after synchronization
wire setpoint_trig_rise = setpoint_trig_sync1 & ~setpoint_trig_sync_d;

always @(posedge clk_i) begin
    if (!rstn_i) begin
        setpoint_index        <= 0;
        sequence_wrap_flag    <= 0;
        setpoint_trig_sync0   <= 0;
        setpoint_trig_sync1   <= 0;
        setpoint_trig_sync_d  <= 0;
    end
    else begin
        // synchronize TTL input
        setpoint_trig_sync0 <= setpoint_trig_i;
        setpoint_trig_sync1 <= setpoint_trig_sync0;
        setpoint_trig_sync_d <= setpoint_trig_sync1;

        // handle reset of sequence
        if (wen && addr==16'h140) begin
            setpoint_index     <= 0;
            sequence_wrap_flag <= 0;
        end

        // manually set index
        if (wen && addr==16'h240) begin
            setpoint_index <= wdata[4-1:0];
        end

        // new sequence
        if (wen && addr==16'h134) begin
            sequence_wrap_flag <= 0;
        end

        // advance on rising edge
        if (setpoint_trig_rise) begin
            if (setpoint_index < SETPOINT_LEN-1) begin
                setpoint_index <= setpoint_index + 1;
            end
            else begin
                setpoint_index     <= 0; // wrap around
                sequence_wrap_flag <= 1; // finished one sequence
            end
        end
    end
end

reg signed [ 14-1: 0] set_sp;   // set point
reg signed [ 14-1: 0] set_ival;   // integral value to set
reg            ival_write;
reg [  3-1: 0] pause_pid_on_sync;  // register to specify which gains (P, I, and/or D) are paused during active sync signal
reg enable_differential_mode;  // register to specify which gains (P, I, and/or D) are paused during active sync signal
wire pause_i_on_sync;
assign pause_i = pause_pid_on_sync[0] & paused_i;
wire pause_p_on_sync;
assign pause_p = pause_pid_on_sync[1] & paused_i;
wire pause_d_on_sync;
assign pause_d = pause_pid_on_sync[2] & paused_i;
reg [ GAINBITS-1: 0] set_kp;   // Kp
reg [ GAINBITS-1: 0] set_ki;   // Ki
reg [ GAINBITS-1: 0] set_kd;   // Kd
reg [ 32-1: 0] set_filter;   // filter setting
// limits if arbitrary saturation is enabled
reg signed [ 14-1:0] out_max;
reg signed [ 14-1:0] out_min;

//  System bus connection
always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      set_sp <= 14'd0;
      set_ival <= 14'd0;
      use_setpoint_sequence <= 1'b0;
      pause_pid_on_sync <= {3{1'b1}};  // by default, all gains are paused on sync signal
      enable_differential_mode <= 1'b0; // by default no differential mode
      set_kp <= {GAINBITS{1'b0}};
      set_ki <= {GAINBITS{1'b0}};
      set_kd <= {GAINBITS{1'b0}};
      set_filter <= 32'd0;
      ival_write <= 1'b0;
      out_min <= {1'b1,{14-1{1'b0}}};
      out_max <= {1'b0,{14-1{1'b1}}};
   end
   else begin
      if (wen) begin
         if (addr==16'h100)   set_ival <= wdata[14-1:0];
         if (addr==16'h104)   set_sp  <= wdata[14-1:0];
         if (addr==16'h130)   use_setpoint_sequence <= wdata[0];
         if (addr==16'h108)   set_kp  <= wdata[GAINBITS-1:0];
         if (addr==16'h10C)   set_ki  <= wdata[GAINBITS-1:0];
         if (addr==16'h110)   set_kd  <= wdata[GAINBITS-1:0];
         if (addr==16'h120)   set_filter  <= wdata;
         if (addr==16'h124)   out_min  <= wdata;
         if (addr==16'h128)   out_max  <= wdata;
         if (addr==16'h12C)   {enable_differential_mode,pause_pid_on_sync} <= wdata[4-1:0];
         if (addr==16'h134) begin
            setpoint_array_write_index <= wdata[17:14];
            setpoint_array[wdata[17:14]] <= wdata[13:0];
         end
      end
      if (addr==16'h100 && wen)
         ival_write <= 1'b1;
      else
         ival_write <= 1'b0;

	  casez (addr)
         16'h100 : begin ack <= wen|ren; rdata <= int_shr; end
         16'h104 : begin ack <= wen|ren; rdata <= {{32-14{1'b0}},set_sp}; end
         16'h108 : begin ack <= wen|ren; rdata <= {{32-GAINBITS{1'b0}},set_kp}; end
         16'h10C : begin ack <= wen|ren; rdata <= {{32-GAINBITS{1'b0}},set_ki}; end
         16'h110 : begin ack <= wen|ren; rdata <= {{32-GAINBITS{1'b0}},set_kd}; end
         16'h120 : begin ack <= wen|ren; rdata <= set_filter; end
         16'h124 : begin ack <= wen|ren; rdata <= {{32-14{1'b0}},out_min}; end
         16'h128 : begin ack <= wen|ren; rdata <= {{32-14{1'b0}},out_max}; end
         16'h12C : begin ack <= wen|ren; rdata <= {{32-4{1'b0}},enable_differential_mode,pause_pid_on_sync}; end
         16'h200 : begin ack <= wen|ren; rdata <= PSR; end
         16'h204 : begin ack <= wen|ren; rdata <= ISR; end
         16'h208 : begin ack <= wen|ren; rdata <= DSR; end
         16'h20C : begin ack <= wen|ren; rdata <= GAINBITS; end
         16'h220 : begin ack <= wen|ren; rdata <= FILTERSTAGES; end
         16'h224 : begin ack <= wen|ren; rdata <= FILTERSHIFTBITS; end
         16'h228 : begin ack <= wen|ren; rdata <= FILTERMINBW; end
         16'h240 : begin ack <= wen|ren; rdata <= {{32-4{1'b0}}, setpoint_index}; end // Report current index
         16'h244 : begin ack <= wen|ren; rdata <= {{32-1{1'b0}}, sequence_wrap_flag}; end // Report wrap status
         16'h24C : begin ack <= wen|ren; rdata <= {{32-14{1'b0}}, setpoint_array[setpoint_index]}; end // Report current setpoint value with zero extension (consistent with setpoint register)
         16'h130 : begin ack <= wen|ren; rdata <= {{32-1{1'b0}}, use_setpoint_sequence}; end
         16'h134 : begin ack <= wen|ren; rdata <= 32'h0; end
         16'h138 : begin
            ack <= wen|ren;
            rdata <= {{32-14{1'b0}},
                     setpoint_array[setpoint_array_write_index]};
         end
	     
	     default: begin ack <= wen|ren;  rdata <=  32'h0; end 
	  endcase	     
   end
end


//-----------------------------
// cascaded set of FILTERSTAGES low- or high-pass filters
wire signed [14-1:0] dat_i_filtered;
red_pitaya_filter_block #(
     .STAGES(FILTERSTAGES),
     .SHIFTBITS(FILTERSHIFTBITS),
     .SIGNALBITS(14),
     .MINBW(FILTERMINBW)
  )
  pidfilter
  (
  .clk_i(clk_i),
  .rstn_i(rstn_i),
  .set_filter(set_filter),
  .dat_i(dat_i),
  .dat_o(dat_i_filtered)
  );

//---------------------------------------------------------------------------------
//  Set point error calculation - 1 cycle delay

reg signed [ 15-1: 0] error        ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      error <= 15'h0 ;
   end
   else begin
      if (enable_differential_mode == 1'b1)
         error <= $signed(dat_i_filtered) - $signed(diff_dat_i) ;
      else
         error <= $signed(dat_i_filtered) - (use_setpoint_sequence ? $signed(setpoint) : $signed(set_sp));
   end
end

// send filtered signal to other pid module for differential processing
assign diff_dat_o = dat_i_filtered;

//---------------------------------------------------------------------------------
//  Proportional part - 1 cycle delay

reg signed  [15+GAINBITS-PSR-1: 0] kp_reg        ;
reg signed  [15+GAINBITS-PSR-1: 0] kp_reg_held   ;
wire signed [15+GAINBITS-1: 0] kp_mult       ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      kp_reg  <= {15+GAINBITS-PSR{1'b0}};
      kp_reg_held <= {15+GAINBITS-PSR{1'b0}};
   end
   else begin
      kp_reg <= kp_mult[15+GAINBITS-1:PSR] ;
      if (pause_p == 1'b0) begin
         kp_reg_held <= kp_mult[15+GAINBITS-1:PSR];
      end
   end
end

assign kp_mult = $signed(error) * $signed(set_kp);

wire signed [15+GAINBITS-PSR-1: 0] kp_final;
assign kp_final = (pause_p == 1'b1) ? kp_reg_held : kp_reg;

//---------------------------------------------------------------------------------
// Integrator - 2 cycles delay (but treat similar to proportional since it
// will become negligible at high frequencies where delay is important)

//formerly
//-localparam IBW = 64; //integrator bit-width. Over-represent the integral sum to record longterm drifts
//-reg   [15+GAINBITS-1: 0] ki_mult  ;
localparam IBW = ISR+14; //integrator bit-width. Over-represent the integral sum to record longterm drifts (overrepresented by 2 bits)
reg signed  [16+GAINBITS-1: 0] ki_mult ; //16 comes from error
wire signed [IBW  : 0] int_sum       ;
reg signed  [IBW-1: 0] int_reg       ;
wire signed [IBW-ISR-1: 0] int_shr   ;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      ki_mult  <= {16+GAINBITS{1'b0}};
      int_reg  <= {IBW{1'b0}};
   end
   else begin
      ki_mult <= $signed(error) * $signed(set_ki) ;
      if (ival_write)
         int_reg <= { set_ival[13:0], {ISR{1'b0}} };
      else if (int_sum[IBW+1-1:IBW+1-2] == 2'b01) //normal positive saturation
         int_reg <= {1'b0,{IBW-1{1'b1}}};
      else if (int_sum[IBW+1-1:IBW+1-2] == 2'b10) // negative saturation
         int_reg <= {1'b1,{IBW-1{1'b0}}};
      else
         int_reg <= int_sum[IBW-1:0]; // use sum as it is
   end
end

assign int_sum = (pause_i==1'b1) ? $signed(int_reg) : $signed(ki_mult) + $signed(int_reg);
assign int_shr = $signed(int_reg[IBW-1:ISR]) ;

//---------------------------------------------------------------------------------
//  Derivative - 2 cycles delay (but treat as 1 cycle because its not
//  functional at the moment

wire signed [    39-1: 0] kd_mult       ;
reg signed  [39-DSR-1: 0] kd_reg        ;
reg signed  [39-DSR-1: 0] kd_reg_r      ;
reg signed  [39-DSR  : 0] kd_reg_s      ;

generate 
	if (DERIVATIVE == 1) begin
		wire  [15+GAINBITS-1: 0] kd_mult;
		reg   [15+GAINBITS-DSR-1: 0] kd_reg;
		reg   [15+GAINBITS-DSR-1: 0] kd_reg_r;
		reg   [15+GAINBITS-DSR  : 0] kd_reg_s;
		always @(posedge clk_i) begin
		   if (rstn_i == 1'b0) begin
		      kd_reg   <= {15+GAINBITS-DSR{1'b0}};
		      kd_reg_r <= {15+GAINBITS-DSR{1'b0}};
		      kd_reg_s <= {15+GAINBITS-DSR+1{1'b0}};
		   end
		   else begin
		      kd_reg   <= kd_mult[15+GAINBITS-1:DSR] ;
		      kd_reg_r <= kd_reg;
		      kd_reg_s <= $signed(kd_reg) - $signed(kd_reg_r); //this is the end result
		   end
		end
        assign kd_mult = (pause_d==1'b1) ? $signed({15+GAINBITS-1{1'b0}}) : $signed(error) * $signed(set_kd);
	end
	else begin
		wire [15+GAINBITS-DSR:0] kd_reg_s;
		assign kd_reg_s = {15+GAINBITS-DSR+1{1'b0}};
	end
endgenerate 

//---------------------------------------------------------------------------------
//  Sum together - saturate output - 1 cycle delay


//maximum possible bitwidth for pid_sum
// = max( 15+GAINBITS(24)-PSR(12) = 27, // from kp_reg
//        IBW(48)-ISR(32) = 16,         // from int_shr
//        39-DSR(10) = 29 but disabled)         // from kd_reg_s
localparam MAXBW = GAINBITS+4; //17

wire signed [   MAXBW-1: 0] pid_sum;
reg signed  [   14-1: 0] pid_out;

always @(posedge clk_i) begin
   if (rstn_i == 1'b0) begin
      pid_out    <= 14'b0;
   end
   else begin
      if ({pid_sum[MAXBW-1],|pid_sum[MAXBW-2:13]} == 2'b01) //positive overflow
         pid_out <= 14'h1FFF;
      else if ({pid_sum[MAXBW-1],&pid_sum[MAXBW-2:13]} == 2'b10) //negative overflow
         pid_out <= 14'h2000;
      else
         pid_out <= pid_sum[14-1:0];
   end
end

assign pid_sum = $signed(kp_final) + $signed(int_shr) + $signed(kd_reg_s);


generate 
	if (ARBITRARY_SATURATION == 0)
		assign dat_o = pid_out;
	else begin
		reg signed [ 14-1:0] out_buffer;
		always @(posedge clk_i) begin
			if (pid_out >= out_max)
				out_buffer <= out_max;
			else if (pid_out <= out_min)
				out_buffer <= out_min;
			else
				out_buffer <= pid_out;
		end
		assign dat_o = out_buffer; 
	end
endgenerate

endmodule
