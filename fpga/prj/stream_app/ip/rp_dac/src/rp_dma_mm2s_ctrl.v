`timescale 1ns / 1ps

module rp_dma_mm2s_ctrl
  #(parameter AXI_ADDR_BITS = 32,  
    parameter AXI_DATA_BITS = 64,
    parameter AXI_BURST_LEN = 16,
    parameter FIFO_CNT_BITS = 9,
    parameter REG_ADDR_BITS = 1,
    parameter CTRL_ADDR     = 1)(
  input  wire                       m_axi_aclk,
  input  wire                       s_axis_aclk,
  input  wire                       m_axi_aresetn,      
  //
  output reg                        busy,
  output reg                        intr,  
  output reg                        mode,

  output reg  [31:0]                reg_ctrl,
  input  wire                       ctrl_val, 
  output reg  [31:0]                reg_sts,
  input  wire                       sts_val, 

  input  wire                       ctrl_reset,
  input  wire                       ctrl_start, 
  input  wire                       ctrl_norm, 
  input  wire                       ctrl_strm, 

  input  wire                       data_valid, 
  output reg                        fifo_rst,
  output wire                       fifo_we_dat,
  input  wire fifo_full,

  input [AXI_ADDR_BITS-1:0]             dac_pntr_step,
  input [AXI_ADDR_BITS-1:0]             dac_buf_size,
  input [AXI_ADDR_BITS-1:0]             dac_buf1_adr,
  input [AXI_ADDR_BITS-1:0]             dac_buf2_adr,
  output [AXI_ADDR_BITS-1:0]            dac_rp,
  output reg                            dac_word,
  output [32-1:0] diag_reg,

  input                                 dac_trig,
  input [ 8-1:0]                        dac_ctrl_reg,
  output [ 5-1:0]                        dac_sts_reg,
  //
  input  wire                           m_axi_dac_arready_i  ,
  input  wire                           m_axi_dac_rvalid_i   ,
  input  wire                           m_axi_dac_rlast_i    ,
  output wire [AXI_ADDR_BITS-1: 0]      m_axi_dac_araddr_o   ,
  output reg  [7:0]                     m_axi_dac_arlen_o    ,
  output reg                            m_axi_dac_arvalid_o  ,
  output wire                           m_axi_dac_rready_o //must be created somehow
);

///////////////////////////////////////////////////////////
// Parameters
//////////////////////////////////////////////////////////// 

localparam IDLE             = 4'd0;
localparam FIFO_RST         = 4'd1;
localparam WAIT_DATA_RDY    = 4'd2;
localparam SEND_DMA_REQ     = 4'd3;
localparam WAIT_DATA_DONE   = 4'd4;
localparam WAIT_BUF_FULL    = 4'd5;

// DMA control reg
localparam CTRL_STRT            = 0;
localparam CTRL_RESET           = 1;
localparam CTRL_MODE_NORM       = 4;
localparam CTRL_MODE_STREAM     = 5;
localparam CTRL_BUF1_RDY        = 6;
localparam CTRL_BUF2_RDY        = 7;

// DMA status reg
localparam READ_STATE_BUF1      = 0;
localparam END_STATE_BUF1       = 1;
localparam READ_STATE_BUF2      = 2;
localparam END_STATE_BUF2       = 3;
localparam RESET_STATE          = 4;


localparam AXI_BURST_BYTES  = AXI_BURST_LEN*AXI_DATA_BITS/8;
localparam BUF_SIZE_BITS    = 17;
localparam ADDR_DECS        = AXI_ADDR_BITS+16;

////////////////////////////////////////////////////////////
// Signals
//////////////////////////////////////////////////////////// 

reg  [3:0]                state_cs;                // Current state
reg  [3:0]                state_ns;                // Next state  
reg  [199:0]              state_ascii;             // ASCII state
reg  [AXI_ADDR_BITS-1:0]  req_addr;
reg  [AXI_ADDR_BITS-1:0]  req_buf_addr;
reg                       req_buf_addr_sel;
reg                       req_buf_addr_sel_p1;
wire                      req_buf_addr_sel_pedge;
wire                      req_buf_addr_sel_nedge;
//wire [7:0]                req_xfer_cnt;
reg                       req_xfer_last;
wire [8:0]                dat_ctrl_req_data;
wire                      dat_ctrl_req_we;
reg                       buf1_rdy;
reg                       buf2_rdy;
reg                       buf1_read;
reg                       buf2_read;
reg                       buf1_ovr;
reg                       buf2_ovr;
reg                       data_valid_reg;
reg  [31:0]               buf1_missed_samp;
reg  [31:0]               buf2_missed_samp;
reg  [3:0]                fifo_rst_cnt;
reg                       fifo_rd_re;
wire                      fifo_empty;
reg                       next_buf_nfull;
reg                       fifo_rst_cntdwn;
reg                       transf_end, transf_end_r;
wire                      m_axi_rready;

wire [7:0] arlen = AXI_BURST_LEN;

reg [7:0] full_cnt;

reg [32-1:0] diag_reg_1;

reg  [ADDR_DECS-1:0]      dac_rp_curr;

wire [ADDR_DECS-1:0]      dac_rp_next   = dac_rp_curr+{15'h0, dac_pntr_step, 1'b0}; //shifted by 1 so that step 1 is a read of 1 address.
wire                      buf_ovr_limit = dac_rp_next[ADDR_DECS-1:16] >= (req_buf_addr+dac_buf_size);  

assign m_axi_dac_araddr_o = req_addr;
assign dac_rp             = req_addr;
assign m_axi_dac_rready_o = m_axi_rready;
assign diag_reg = diag_reg_1;

assign fifo_we_dat = (dac_rp_curr[ADDR_DECS-1:16+1] != req_addr[AXI_ADDR_BITS-1:1]);

wire fifo_wait_full = (full_cnt == 'h0);
always @(posedge m_axi_aclk)
begin
  transf_end_r <= transf_end; // full signal in the last 2 clocks of transfer crashes the SM
  if (m_axi_aresetn == 0) begin
    full_cnt <= 'h0;
  end else begin
    if (fifo_full && fifo_wait_full && ~(transf_end || transf_end_r) && (state_cs == SEND_DMA_REQ || state_cs == WAIT_DATA_RDY))
      full_cnt <= 'h1;
    
    case (state_cs)
    SEND_DMA_REQ: begin
      if (|full_cnt && m_axi_dac_rvalid_i) begin
        if (full_cnt < AXI_BURST_LEN)
          full_cnt <= full_cnt + 'h1;
        else
          full_cnt <= 'h0;
      end
    end

      WAIT_DATA_RDY: begin
        if (|full_cnt) begin
          if (full_cnt < AXI_BURST_LEN)
            full_cnt <= full_cnt + 'h1;
          else
            full_cnt <= 'h0;
        end
      end
    endcase
  end
end

reg fifo_full_reg;
always @(posedge m_axi_aclk)
begin
  if (transf_end) // was the fifo full at the end of the last transfer?
    fifo_full_reg <= fifo_wait_full;
end

////////////////////////////////////////////////////////////
// Name : Data Control
// 
////////////////////////////////////////////////////////////
  
rp_dma_mm2s_data_ctrl U_dma_mm2s_data_ctrl(
  .m_axi_aclk     (m_axi_aclk),            
  .m_axi_aresetn  (m_axi_aresetn),                  
  .fifo_rst       (fifo_rst),              
  .fifo_full      (~fifo_wait_full),
  .req_data       (dat_ctrl_req_data),              
  .req_we         (dat_ctrl_req_we),            
  .m_axi_rvalid   (m_axi_dac_rvalid_i),          
  .m_axi_rready   (m_axi_rready),          
  .m_axi_rlast    (m_axi_dac_rlast_i));
  
assign dat_ctrl_req_data = (arlen*2);
assign dat_ctrl_req_we   = (m_axi_dac_arvalid_o  & m_axi_dac_arready_i); // writing data buffer is only enabled when not waiting on clearing of the next buffer. 
        
////////////////////////////////////////////////////////////
// Name : State machine seq logic
// Sets the current state to the next state.
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0) begin
    state_cs <= IDLE;
  end else begin
    state_cs <= state_ns;
  end
end

////////////////////////////////////////////////////////////
// Name : Diag reg
// Sets AXI diag reg
////////////////////////////////////////////////////////////
assign req_buf_addr_sel_pedge =  req_buf_addr_sel & ~req_buf_addr_sel_p1;
assign req_buf_addr_sel_nedge = ~req_buf_addr_sel &  req_buf_addr_sel_p1;
reg [32-1:0] bufcnt;

always @(posedge m_axi_aclk)
begin
  req_buf_addr_sel_p1 <= req_buf_addr_sel;
  //                               4                                                                                  3                                                          2                                         1                  0
  diag_reg_1 <= {{m_axi_dac_arready_i,m_axi_dac_rvalid_i,m_axi_dac_rlast_i,m_axi_dac_arvalid_o},{1'b0,transf_end,dat_ctrl_req_we,m_axi_rready},{1'b0,dat_ctrl_req_we,req_buf_addr_sel,next_buf_nfull},{2'b0,fifo_full_reg,fifo_wait_full},state_cs};
end

////////////////////////////////////////////////////////////
// Name : Status reg
// Sets status reg
////////////////////////////////////////////////////////////
always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0) begin
    reg_sts <= 32'h0;
  end else begin
    reg_sts[31:5] <= 27'd0;
    reg_sts[END_STATE_BUF1]   <= (((state_cs == WAIT_BUF_FULL)) && ~req_buf_addr_sel);
    reg_sts[READ_STATE_BUF1]  <= (state_cs == WAIT_DATA_RDY  && ~req_buf_addr_sel);
    reg_sts[END_STATE_BUF2]   <= (((state_cs == WAIT_BUF_FULL)) &&  req_buf_addr_sel);
    reg_sts[READ_STATE_BUF2]  <= (state_cs == WAIT_DATA_RDY  &&  req_buf_addr_sel);
    reg_sts[RESET_STATE] <= (state_cs == FIFO_RST);
  end
end

////////////////////////////////////////////////////////////
// Name : data_valid synchronisation
// data valid must be delayed by one clock to align with 
// axi signals
////////////////////////////////////////////////////////////
always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0) begin
    data_valid_reg <= 1'b0;
  end else begin
    data_valid_reg <= data_valid;
  end
end

////////////////////////////////////////////////////////////
// Name : State machine ascii 
// Converts the state to ascii for debug.
////////////////////////////////////////////////////////////

always @(*)
begin
  case (state_cs)
    IDLE:           state_ascii = "IDLE";
    FIFO_RST:       state_ascii = "FIFO_RST";
    WAIT_DATA_RDY:  state_ascii = "WAIT_DATA_RDY";            
    SEND_DMA_REQ:   state_ascii = "SEND_DMA_REQ";       
    WAIT_DATA_DONE: state_ascii = "WAIT_DATA_DONE";
    WAIT_BUF_FULL:  state_ascii = "WAIT_BUF_FULL";  
  endcase
end

////////////////////////////////////////////////////////////
// Name : State machine comb logic
// Assigns the next state.
////////////////////////////////////////////////////////////

always @(*)
begin
  state_ns = state_cs;

  case (state_cs)
    // IDLE - Wait for the DMA start signal
    IDLE: begin
      if (reg_ctrl[CTRL_STRT] == 1) begin
        state_ns = FIFO_RST;
      end
    end
    
    // FIFO_RST - Reset the data FIFO
    FIFO_RST: begin
      if (reg_ctrl[CTRL_RESET])
        state_ns = IDLE;
      else if (fifo_rst_cnt == 15) begin
        state_ns = WAIT_DATA_RDY;
      end
    end
    
    // WAIT_DATA_RDY - Wait for the data to be buffered before sending the request
    WAIT_DATA_RDY: begin
      if (reg_ctrl[CTRL_RESET])
        state_ns = IDLE;
      else begin
        if (fifo_full_reg)
          state_ns = SEND_DMA_REQ;
        else begin
          if (fifo_wait_full)
            state_ns = SEND_DMA_REQ;
        end
      end
    end

    // SEND_DMA_REQ - Send the request 
    SEND_DMA_REQ: begin

        if (reg_ctrl[CTRL_RESET])
          state_ns = IDLE;
        else if (transf_end) begin
          if (next_buf_nfull) // if next transfer results in overwriting the buffer, wait until the buffer is completely read out.
           state_ns = WAIT_BUF_FULL;
          else
            state_ns = WAIT_DATA_RDY;     
          //end  
        end  
    end    
    
    WAIT_BUF_FULL: begin
      if (reg_ctrl[CTRL_RESET])
          state_ns = IDLE;
      else if (~next_buf_nfull) begin // if next buffer is full, then wait
        state_ns = FIFO_RST; // go back to filling FIFOs
      end
    end

  endcase
end

////////////////////////////////////////////////////////////
// Name : Control Register
// 
////////////////////////////////////////////////////////////
always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0) begin
    reg_ctrl <= 0;
  end else begin
    if (ctrl_val) begin
      reg_ctrl <= dac_ctrl_reg;
    end else begin
      // Start
      if (reg_ctrl[CTRL_STRT] == 1) begin
        reg_ctrl[CTRL_STRT] <= 0;
      end
      // Reset state machine
      if (reg_ctrl[CTRL_RESET]) begin
        reg_ctrl[CTRL_RESET] <= 0;
      end   
      // Mode normal
      if (reg_ctrl[CTRL_MODE_NORM] == 1) begin
        reg_ctrl[CTRL_MODE_NORM] <= 0;
      end            

      // Mode streaming
      if (reg_ctrl[CTRL_MODE_STREAM] == 1) begin
        reg_ctrl[CTRL_MODE_STREAM] <= 0;
      end

      // Mode streaming
      if (reg_ctrl[CTRL_BUF1_RDY] == 1) begin
        reg_ctrl[CTRL_BUF1_RDY] <= 0;
      end

      // Mode streaming
      if (reg_ctrl[CTRL_BUF2_RDY] == 1) begin
        reg_ctrl[CTRL_BUF2_RDY] <= 0;
      end

    end
  end
end

////////////////////////////////////////////////////////////
// Transfer end
// All data has been transferred
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0)
    transf_end <= 0;
  else begin
    if ((m_axi_dac_rvalid_i == 1) && (m_axi_dac_rlast_i == 1))
      transf_end <= 1'b1;
    else 
      transf_end <= 1'b0;
  end
end

////////////////////////////////////////////////////////////
// FIFO reset countdown active
// only activates after data loss FIFO reset
// used to increase missed sample counter during FIFO reset
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  case (state_cs)

    WAIT_BUF_FULL: begin
      if (~next_buf_nfull) begin // if next buffer is full, then wait
        fifo_rst_cntdwn <= 1'b1; // go back to filling FIFOs
      end
    end

    FIFO_RST: begin
      if (fifo_rst_cnt == 15) begin
        fifo_rst_cntdwn <= 1'b0;
      end
      if (reg_ctrl[CTRL_RESET])
        fifo_rst_cntdwn <= 1'b0;
    end     

    default: begin
        fifo_rst_cntdwn <= 1'b0;
      end

  endcase
end  

////////////////////////////////////////////////////////////
// Name : DMA Mode
// 0 = Normal
// 1 = Streaming
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0) begin
    mode <= 0;
  end else begin
    if (reg_ctrl[CTRL_MODE_NORM] == 1) begin
      mode <= 0;
    end
    
    if (reg_ctrl[CTRL_MODE_STREAM] == 1) begin
      mode <= 1;
    end    
  end
end

////////////////////////////////////////////////////////////
// next buffer is still not full
////////////////////////////////////////////////////////////
 
always @(posedge m_axi_aclk)
begin
  case (state_cs)
    // IDLE - Wait for the DMA start signal
    IDLE: begin
      next_buf_nfull <= 0;  
    end    

    default: begin
        if (reg_ctrl[CTRL_BUF1_RDY] || reg_ctrl[CTRL_BUF2_RDY])
            next_buf_nfull <= 0;
        else if (buf_ovr_limit) begin
          if (((req_buf_addr_sel == 0) && ~buf2_rdy) || ((req_buf_addr_sel == 1) && ~buf1_rdy)) begin // data loss is occuring
            next_buf_nfull <= 1;  
          end
        end 
      end          
  endcase
end  

////////////////////////////////////////////////////////////
// Name : Buffer 1 Full
// Set when buffer 1 is full.
////////////////////////////////////////////////////////////
 
always @(posedge m_axi_aclk)
begin
  case (state_cs)
    // IDLE - Wait for the DMA start signal
    IDLE: begin
      buf1_rdy <= 0;  
    end 
    default: begin
      if (reg_ctrl[CTRL_BUF1_RDY] == 1) begin
        buf1_rdy <= 1;     
      end else begin
        // Reset to the start of the buffer if we have reached the end
        if (buf_ovr_limit) begin
          if (req_buf_addr_sel == 0 && buf1_rdy) begin // buffer 1 is full if next transfer goes over specified buffer size
            buf1_rdy <= 0;
          end
        end
      end     
    end
  endcase
end  

////////////////////////////////////////////////////////////
// Name : Buffer 2 Full
// Set when buffer 2 is full.
////////////////////////////////////////////////////////////
 
always @(posedge m_axi_aclk)
begin
  case (state_cs)
    // IDLE - Wait for the DMA start signal
    IDLE: begin
      buf2_rdy <= 0;  
    end 
    default: begin
      if (reg_ctrl[CTRL_BUF2_RDY] == 1) begin
        buf2_rdy <= 1;     
      end else begin
        // Reset to the start of the buffer if we have reached the end
        if (buf_ovr_limit) begin
          if (req_buf_addr_sel == 1 && buf2_rdy) begin // buffer 1 is full if next transfer goes over specified buffer size
            buf2_rdy <= 0;
          end
        end
      end     
    end
  endcase
end  

////////////////////////////////////////////////////////////
// Name : Request Address
// Holds the address of the buffer in memory where data will
// be read.
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0)
    req_addr <= 'h0;
  else begin
    case (state_cs)
      // IDLE - Wait for the DMA start signal
      IDLE: begin
        req_addr <= req_buf_addr;  
      end
      
      SEND_DMA_REQ: begin
        if (m_axi_dac_rvalid_i && m_axi_rready) begin
          if (buf_ovr_limit || dac_trig) begin
            if ((req_buf_addr_sel == 0) && buf2_rdy) begin //only start writing to buf2 if it's full
              req_addr <= dac_buf2_adr;          
            end 
            if ((req_buf_addr_sel == 1) && buf1_rdy) begin //only start writing to buf1 if it's full
              req_addr <= dac_buf1_adr;
            end             
          end else begin
            req_addr <= {dac_rp_curr[ADDR_DECS-1:16+2], 2'b0}; //reading every 32 bits (4 bytes)
          end
        end  
      end

      WAIT_BUF_FULL: begin
        if (~next_buf_nfull) begin
          // Swap the buffer if we have reached the end of the current one
            if ((req_buf_addr_sel == 0) && buf2_rdy) begin // only switch addresses when next buffer is read out
              req_addr <= dac_buf2_adr;          
            end 
            if ((req_buf_addr_sel == 1) && buf1_rdy) begin
              req_addr <= dac_buf1_adr;
            end        
        end   
      end   

    endcase
  end
end

/////////////////////////////////////////////////////////////////
// Name : Data word
// need to determine which part of the 32 bit read must be used
// reject last bit as we need 16 bits, not 8
// 0: bits 15:0
// 1: bits 31:16
/////////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0)
    dac_word <= 'h0;
  else begin
    case (state_cs)
      // IDLE - Wait for the DMA start signal
      IDLE: begin
        dac_word <= req_buf_addr[1];  
      end
      
      SEND_DMA_REQ: begin
        if (m_axi_dac_rvalid_i && m_axi_rready) begin
          if (buf_ovr_limit || dac_trig) begin
            if ((req_buf_addr_sel == 0) && buf2_rdy) begin
              dac_word <= dac_buf2_adr[1]; 
            end 
            if ((req_buf_addr_sel == 1) && buf1_rdy) begin
              dac_word <= dac_buf1_adr[1];
            end             
          end else begin
            dac_word <= dac_rp_curr[17];
          end
        end  
      end

      WAIT_BUF_FULL: begin
        if (~next_buf_nfull) begin
            if ((req_buf_addr_sel == 0) && buf2_rdy) begin
              dac_word <= dac_buf2_adr[1];          
            end 
            if ((req_buf_addr_sel == 1) && buf1_rdy) begin
              dac_word <= dac_buf1_adr[1];
            end        
        end   
      end   

    endcase
  end
end

////////////////////////////////////////////////////////////
// Name : Read pointer
// Calculating the next read pointer
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0)
    dac_rp_curr <= 'h0;
  else begin
    case (state_cs)
      // IDLE - Wait for the DMA start signal
      IDLE: begin
        dac_rp_curr <= {req_buf_addr, 16'h0};  
      end
      
      SEND_DMA_REQ: begin
        if (m_axi_dac_rvalid_i && m_axi_rready) begin
          if (buf_ovr_limit || dac_trig) begin
            if ((req_buf_addr_sel == 0) && buf2_rdy) begin //only start writing to buf2 if it's full
              dac_rp_curr <= {dac_buf2_adr, 16'h0};      
            end 
            if ((req_buf_addr_sel == 1) && buf1_rdy) begin //only start writing to buf1 if it's full
              dac_rp_curr <= {dac_buf1_adr, 16'h0};      
            end             
          end else begin
            dac_rp_curr <= dac_rp_next;
          end
        end  
      end

      WAIT_BUF_FULL: begin
        if (~next_buf_nfull) begin
          // Swap the buffer if we have reached the end of the current one
            if ((req_buf_addr_sel == 0) && buf2_rdy) begin // only switch addresses when next buffer is read out
              dac_rp_curr <= {dac_buf2_adr, 16'h0};      
            end 
            if ((req_buf_addr_sel == 1) && buf1_rdy) begin
              dac_rp_curr <= {dac_buf1_adr, 16'h0};      
            end        
        end   
      end   
    endcase
  end
end

////////////////////////////////////////////////////////////
// Name : Request Buffer Address Select
// Selects the current buffer to use in memory.
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  case (state_cs)
    // IDLE - Wait for the DMA start signal
    IDLE: begin
      req_buf_addr <= dac_buf1_adr;  
    end  
    
    SEND_DMA_REQ: begin
      if (buf_ovr_limit) begin
        if ((req_buf_addr_sel == 0) && buf2_rdy) begin //only start writing to buf2 if it's full
          req_buf_addr <= dac_buf2_adr;          
        end 
        if ((req_buf_addr_sel == 1) && buf1_rdy) begin //only start writing to buf1 if it's full
          req_buf_addr <= dac_buf1_adr;
        end   
      end
    end       

    WAIT_BUF_FULL: begin
      if (~next_buf_nfull) begin
        // Swap the buffer if we have reached the end of the current one
          if ((req_buf_addr_sel == 0) && buf2_rdy) begin // only switch addresses when next buffer is read out
            req_buf_addr <= dac_buf2_adr;          
          end 
          if ((req_buf_addr_sel == 1) && buf1_rdy) begin
            req_buf_addr <= dac_buf1_adr;
          end  
        end      
      end   
  endcase
end

////////////////////////////////////////////////////////////
// Name : Request Buffer Address Select
// Selects the current buffer to use in memory.
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  case (state_cs)
    // IDLE - Wait for the DMA start signal
    IDLE: begin
      req_buf_addr_sel <= 0;  
    end  
    
    SEND_DMA_REQ: begin
      if (buf_ovr_limit) begin
        if ((req_buf_addr_sel == 1) && buf1_rdy)
          req_buf_addr_sel <= 1'b0;
        
        if ((req_buf_addr_sel == 0) && buf2_rdy) 
          req_buf_addr_sel <= 1'b1;
      end  
    end  
    
    FIFO_RST: begin // only happens when exiting FIFO reset state after data loss
      if (fifo_rst_cntdwn && (&fifo_rst_cnt)) begin
          req_buf_addr_sel <= ~req_buf_addr_sel;
        end      
      end        
  endcase
end

////////////////////////////////////////////////////////////
// Name : Busy
// Signals when the DMA is busy.
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  case (state_cs) 
    // IDLE - Wait for the DMA start signal
    IDLE: begin
      if (reg_ctrl[CTRL_STRT] == 1) begin
        busy <= 1;
      end else begin
        busy <= 0;
      end
    end 
  endcase  
end

////////////////////////////////////////////////////////////
// Name : FIFO Reset 
// Resets the Xilinx FIFOs
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  case (state_cs) 
    // FIFO_RST - Reset the data FIFO
    FIFO_RST: begin
      if (fifo_rst_cnt < 1) begin
        fifo_rst <= 1;  
      end else begin
        fifo_rst <= 0;
      end
    end   
  
    default: begin
      fifo_rst <= 0;
    end   
  endcase  
end

////////////////////////////////////////////////////////////
// Name : FIFO Reset Count
// The Xilinx FIFO needs a certain reset time.
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  case (state_cs) 
   // FIFO_RST - Reset the data FIFO
    FIFO_RST: begin
      fifo_rst_cnt <= fifo_rst_cnt + 1;
    end   
  
    default: begin
      fifo_rst_cnt <= 0;
    end   
  endcase   
end

////////////////////////////////////////////////////////////
// Name : Master AXI ARVALID
// 
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  if (m_axi_aresetn == 0) begin
    m_axi_dac_arvalid_o <= 0;
  end else begin
    case (state_cs) 
       // WAIT_DATA_RDY - Wait until there is enough data to send an AXI transfer
      WAIT_DATA_RDY: begin
        if (fifo_wait_full)
          m_axi_dac_arvalid_o <= 1;  
        else if (full_cnt > arlen-2) 
          m_axi_dac_arvalid_o <= 1;  
      end
      
      SEND_DMA_REQ: begin
        if ((m_axi_dac_arvalid_o == 1) && (m_axi_dac_arready_i == 1)) begin
          m_axi_dac_arvalid_o <= 0;  
        end  
      end          

      default: begin
        m_axi_dac_arvalid_o <= 0;  
      end    
    endcase   
  end
end

////////////////////////////////////////////////////////////
// Name : Master AXI AWLEN
// 
////////////////////////////////////////////////////////////

always @(posedge m_axi_aclk)
begin
  case (state_cs) 
    // WAIT_DATA_RDY - Wait until there is enough data to send an AXI transfer
    WAIT_DATA_RDY: begin
      m_axi_dac_arlen_o <= arlen-1;
    end

    

  endcase   
end

endmodule