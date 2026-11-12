set sdc_version 2.1

set_units -time ps -resistance kOhm -capacitance fF -voltage V -current mA
set_wire_load_mode segmented
set_max_fanout 16 [current_design]

create_clock -name clk -period 2000 [get_ports clk]
set_clock_uncertainty 0.01 [get_clocks clk]
set_clock_transition -max -rise 0.1 [get_clocks clk]
set_clock_transition -max -fall 0.1 [get_clocks clk]
set_clock_transition -min -rise 0.1 [get_clocks clk]
set_clock_transition -min -fall 0.1 [get_clocks clk]

set_driving_cell -lib_cell INVx3_ASAP7_75t_R [remove_from_collection [all_inputs] [get_ports clk]]
set_input_delay 0.1 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.1 -clock clk [all_outputs]
set_load 0.01 [all_outputs]
