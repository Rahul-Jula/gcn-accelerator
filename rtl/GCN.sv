module GCN
  #(parameter FEATURE_COLS = 96,
    parameter WEIGHT_ROWS = 96,
    parameter FEATURE_ROWS = 6,
    parameter WEIGHT_COLS = 3,
    parameter FEATURE_WIDTH = 5,
    parameter WEIGHT_WIDTH = 5,
    parameter DOT_PROD_WIDTH = 16,
    parameter ADDRESS_WIDTH = 13,
    parameter COUNTER_WEIGHT_WIDTH = $clog2(WEIGHT_COLS),
    parameter COUNTER_FEATURE_WIDTH = $clog2(FEATURE_ROWS),
    parameter MAX_ADDRESS_WIDTH = 2,
    parameter NUM_OF_NODES = 6,
    parameter COO_NUM_OF_COLS = 6,
    parameter COO_NUM_OF_ROWS = 2,
    parameter COO_BW = $clog2(COO_NUM_OF_COLS)
)
(
  input  logic clk,
  input  logic reset,
  input  logic start,
  input  logic [WEIGHT_WIDTH-1:0]      data_in      [0:WEIGHT_ROWS-1],
  input  logic [COO_BW-1:0]            coo_in       [0:1],

  output logic [COO_BW-1:0]            coo_address,
  output logic [ADDRESS_WIDTH-1:0]     read_address,
  output logic                         enable_read,
  output logic                         done,
  output logic [MAX_ADDRESS_WIDTH-1:0] max_addi_answer [0:FEATURE_ROWS-1]
);

  logic fsm_enable_read;
  logic fsm_enable_scratch_pad;
  logic fsm_enable_weight_counter;
  logic fsm_enable_feature_counter;
  logic fsm_enable_write_fm_wm_prod;
  logic fsm_read_feature_or_weight;
  logic fsm_enable_write;
  logic fsm_done;

  logic [COUNTER_WEIGHT_WIDTH-1:0]  weight_count;
  logic [COUNTER_FEATURE_WIDTH-1:0] feature_count;

  logic [WEIGHT_WIDTH-1:0] scratch_out [0:WEIGHT_ROWS-1];
  logic [DOT_PROD_WIDTH-1:0] dot_product;

  logic [COUNTER_FEATURE_WIDTH-1:0] fmwm_write_row;
  logic [COUNTER_WEIGHT_WIDTH-1:0]  fmwm_write_col;
  logic [COUNTER_FEATURE_WIDTH-1:0] fmwm_read_row;
  logic [DOT_PROD_WIDTH-1:0]        fmwm_row_out [0:WEIGHT_COLS-1];

  logic [COUNTER_FEATURE_WIDTH-1:0] adj_write_row;
  logic [COUNTER_FEATURE_WIDTH-1:0] adj_read_row_comb;
  logic [COUNTER_FEATURE_WIDTH-1:0] adj_read_row_arg;
  logic [COUNTER_FEATURE_WIDTH-1:0] adj_read_row;
  logic [DOT_PROD_WIDTH-1:0]        adj_row_in   [0:WEIGHT_COLS-1];
  logic [DOT_PROD_WIDTH-1:0]        adj_row_out  [0:WEIGHT_COLS-1];
  logic                             adj_wr_en;

  typedef enum logic [3:0] {
    COMB_IDLE       = 4'd0,
    COMB_EDGE_LATCH = 4'd1,
    COMB_REQ_SRC    = 4'd2,
    COMB_READ_DST   = 4'd3,
    COMB_WRITE_DST  = 4'd4,
    COMB_REQ_DST    = 4'd5,
    COMB_READ_SRC   = 4'd6,
    COMB_WRITE_SRC  = 4'd7,
    COMB_DONE_ST    = 4'd8
  } comb_state_t;
  comb_state_t comb_state;

  typedef enum logic [1:0] {
    ARG_IDLE    = 2'd0,
    ARG_REQ     = 2'd1,
    ARG_WAIT    = 2'd2,
    ARG_DONE_ST = 2'd3
  } arg_state_t;
  arg_state_t arg_state;

  logic [2:0] aggr_counter;
  logic [COO_BW-1:0] coo_src;
  logic [COO_BW-1:0] coo_dst;
  logic comb_done_flag;

  logic [DOT_PROD_WIDTH-1:0] src_fmwm_buf [0:WEIGHT_COLS-1];
  logic [DOT_PROD_WIDTH-1:0] dst_fmwm_buf [0:WEIGHT_COLS-1];

  logic [COUNTER_FEATURE_WIDTH-1:0] arg_node_counter;
  logic all_done;

  always_comb begin
    if (fsm_read_feature_or_weight) begin
      read_address = ADDRESS_WIDTH'(13'h200) + ADDRESS_WIDTH'(feature_count);
    end else begin
      read_address = ADDRESS_WIDTH'(weight_count);
    end
    enable_read = fsm_enable_read;
  end

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      weight_count  <= '0;
      feature_count <= '0;
    end else begin
      if (fsm_enable_weight_counter) begin
        if (weight_count == WEIGHT_COLS - 1)
          weight_count <= '0;
        else
          weight_count <= weight_count + 1'b1;
      end
      if (fsm_enable_feature_counter) begin
        if (feature_count == FEATURE_ROWS - 1)
          feature_count <= '0;
        else
          feature_count <= feature_count + 1'b1;
      end
    end
  end

  always_comb begin : dot_product_calc
    logic [DOT_PROD_WIDTH-1:0] acc;
    acc = '0;
    for (int k = 0; k < WEIGHT_ROWS; k++) begin
      acc = acc + (DOT_PROD_WIDTH'(data_in[k]) * DOT_PROD_WIDTH'(scratch_out[k]));
    end
    dot_product = acc;
  end

  assign fmwm_write_row = feature_count;
  assign fmwm_write_col = weight_count;

  Transformation_FSM #(
    .FEATURE_ROWS          (FEATURE_ROWS),
    .WEIGHT_COLS           (WEIGHT_COLS)
  ) u_fsm (
    .clk                    (clk),
    .reset                  (reset),
    .start                  (start),
    .weight_count           (weight_count),
    .feature_count          (feature_count),
    .enable_write_fm_wm_prod(fsm_enable_write_fm_wm_prod),
    .enable_read            (fsm_enable_read),
    .enable_write           (fsm_enable_write),
    .enable_scratch_pad     (fsm_enable_scratch_pad),
    .enable_weight_counter  (fsm_enable_weight_counter),
    .enable_feature_counter (fsm_enable_feature_counter),
    .read_feature_or_weight (fsm_read_feature_or_weight),
    .done                   (fsm_done)
  );

  Scratch_Pad #(
    .WEIGHT_ROWS  (WEIGHT_ROWS),
    .WEIGHT_WIDTH (WEIGHT_WIDTH)
  ) u_scratch (
    .clk           (clk),
    .reset         (reset),
    .write_enable  (fsm_enable_scratch_pad),
    .weight_col_in (data_in),
    .weight_col_out(scratch_out)
  );

  Matrix_FM_WM_Memory #(
    .FEATURE_ROWS   (FEATURE_ROWS),
    .WEIGHT_COLS    (WEIGHT_COLS),
    .DOT_PROD_WIDTH (DOT_PROD_WIDTH)
  ) u_fmwm_mem (
    .clk           (clk),
    .rst           (reset),
    .write_row     (fmwm_write_row),
    .write_col     (fmwm_write_col),
    .read_row      (fmwm_read_row),
    .wr_en         (fsm_enable_write_fm_wm_prod),
    .fm_wm_in      (dot_product),
    .fm_wm_row_out (fmwm_row_out)
  );

  assign adj_read_row = (comb_done_flag) ? adj_read_row_arg : adj_read_row_comb;

  Matrix_FM_WM_ADJ_Memory #(
    .FEATURE_ROWS   (FEATURE_ROWS),
    .WEIGHT_COLS    (WEIGHT_COLS),
    .DOT_PROD_WIDTH (DOT_PROD_WIDTH)
  ) u_adj_mem (
    .clk              (clk),
    .rst              (reset),
    .write_row        (adj_write_row),
    .read_row         (adj_read_row),
    .wr_en            (adj_wr_en),
    .fm_wm_adj_row_in (adj_row_in),
    .fm_wm_adj_out    (adj_row_out)
  );

  assign coo_address = aggr_counter;

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      comb_state       <= COMB_IDLE;
      aggr_counter     <= '0;
      coo_src          <= '0;
      coo_dst          <= '0;
      fmwm_read_row    <= '0;
      adj_read_row_comb<= '0;
      adj_write_row    <= '0;
      adj_wr_en        <= 1'b0;
      comb_done_flag   <= 1'b0;
      for (int i = 0; i < WEIGHT_COLS; i++) begin
        adj_row_in[i]   <= '0;
        src_fmwm_buf[i] <= '0;
        dst_fmwm_buf[i] <= '0;
      end
    end else begin
      adj_wr_en <= 1'b0;

      case (comb_state)
        COMB_IDLE: begin
          aggr_counter   <= '0;
          comb_done_flag <= 1'b0;
          if (fsm_done)
            comb_state <= COMB_EDGE_LATCH;
        end

        COMB_EDGE_LATCH: begin
          coo_src    <= coo_in[0] - 1'b1;
          coo_dst    <= coo_in[1] - 1'b1;
          comb_state <= COMB_REQ_SRC;
        end

        COMB_REQ_SRC: begin
          fmwm_read_row <= coo_src;
          comb_state    <= COMB_READ_DST;
        end

        COMB_READ_DST: begin
          for (int c = 0; c < WEIGHT_COLS; c++) begin
            src_fmwm_buf[c] <= fmwm_row_out[c];
          end
          adj_read_row_comb <= coo_dst;
          comb_state        <= COMB_WRITE_DST;
        end

        COMB_WRITE_DST: begin
          adj_write_row <= coo_dst;
          for (int c = 0; c < WEIGHT_COLS; c++) begin
            adj_row_in[c] <= adj_row_out[c] + src_fmwm_buf[c];
          end
          adj_wr_en   <= 1'b1;
          comb_state  <= COMB_REQ_DST;
        end

        COMB_REQ_DST: begin
          fmwm_read_row <= coo_dst;
          comb_state    <= COMB_READ_SRC;
        end

        COMB_READ_SRC: begin
          for (int c = 0; c < WEIGHT_COLS; c++) begin
            dst_fmwm_buf[c] <= fmwm_row_out[c];
          end
          adj_read_row_comb <= coo_src;
          comb_state        <= COMB_WRITE_SRC;
        end

        COMB_WRITE_SRC: begin
          adj_write_row <= coo_src;
          for (int c = 0; c < WEIGHT_COLS; c++) begin
            adj_row_in[c] <= adj_row_out[c] + dst_fmwm_buf[c];
          end
          adj_wr_en <= 1'b1;

          if (aggr_counter == COO_NUM_OF_COLS - 1) begin
            comb_state <= COMB_DONE_ST;
          end else begin
            aggr_counter <= aggr_counter + 1'b1;
            comb_state   <= COMB_EDGE_LATCH;
          end
        end

        COMB_DONE_ST: begin
          comb_done_flag <= 1'b1;
        end

        default: begin
          comb_state <= COMB_IDLE;
        end
      endcase
    end
  end

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      arg_state        <= ARG_IDLE;
      arg_node_counter <= '0;
      adj_read_row_arg <= '0;
      all_done         <= 1'b0;
      for (int i = 0; i < FEATURE_ROWS; i++) begin
        max_addi_answer[i] <= '0;
      end
    end else begin
      case (arg_state)
        ARG_IDLE: begin
          arg_node_counter <= '0;
          all_done         <= 1'b0;
          if (comb_done_flag)
            arg_state <= ARG_REQ;
        end

        ARG_REQ: begin
          adj_read_row_arg <= arg_node_counter;
          arg_state        <= ARG_WAIT;
        end

        ARG_WAIT: begin
          if ((adj_row_out[2] > adj_row_out[0]) && (adj_row_out[2] > adj_row_out[1]))
            max_addi_answer[arg_node_counter] <= 2'd2;
          else if (adj_row_out[1] > adj_row_out[0])
            max_addi_answer[arg_node_counter] <= 2'd1;
          else
            max_addi_answer[arg_node_counter] <= 2'd0;

          if (arg_node_counter == FEATURE_ROWS - 1) begin
            arg_state <= ARG_DONE_ST;
          end else begin
            arg_node_counter <= arg_node_counter + 1'b1;
            arg_state        <= ARG_REQ;
          end
        end

        ARG_DONE_ST: begin
          all_done <= 1'b1;
        end

        default: begin
          arg_state <= ARG_IDLE;
        end
      endcase
    end
  end

  assign done = all_done;

endmodule
