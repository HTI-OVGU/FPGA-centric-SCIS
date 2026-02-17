top_w5500_file=src/w5500/top_w5500.vhd
top_for_tb_w5500=src/w5500/top_for_tb_w5500.vhd
testbench_w5500=src/w5500/tb_top_w5500.vhd
fsm = src/w5500/w5500_state_machine.vhd
external_data_handler = src/w5500/ext_data_handler.vhd
spi_master = src/w5500/spi_master.vhd
axis_data_fifo = src/axis_data_fifo.vhd
stalling_axis_data_fifo = src/stalling_axi_data_fifo.vhd
data_streamer = src/w5500/spi_streamer.vhd
stream_manager = src/w5500/w5500_stream_manager.vhd
bram_dp_write_through = src/bram_dp_write_through.vhd

metric_packet_stream_interface = src/data_concentrator/metric_packet_stream_interface.vhd

metric_packet_fifo = src/data_concentrator/metric_packet_fifo.vhd
priority_axis_data_fifo = src/data_concentrator/priority_fifo.vhd
data_concentrator = src/data_concentrator/data_concentrator.vhd
udp_packet_adapter = src/data_concentrator/udp_packet_adapter.vhd
metric_packet_manager = src/data_concentrator/metric_packet_manager.vhd
threshold_logic = src/data_concentrator/threshold_logic.vhd 
bram_threshold_lookup = src/data_concentrator/bram_threshold_lookup.vhd
telemetry_sender = src/data_concentrator/telemetry_sender.vhd
interlock_glitch_filter = src/data_concentrator/interlock_glitch_filter.vhd

data_concentrator_testbench = src/data_concentrator/tb_data_concentrator.vhd

testbench_spimaster = src/w5500/tb_spimaster.vhd

# TOP FILE FOR BOTH W5500 and DataConcentrator (instead of external Data handler)
top_file = src/top.vhd
top_for_tb_w5500_and_dc = src/top_for_w5500_and_dc_tb.vhd
tb_for_w5500_and_dc = src/tb_top_w5500_and_dc.vhd

verilog_net_export = net/top_synth.v
design_json_export = design.json

constraints_file_w5500 = src/w5500.ccf
constraints_file_all = src/constraints_dc_and_w5500.ccf
impl_file = implementation.txt
bit_file = bitstream.bit

sim_spimaster:
	ghdl -a $(testbench_spimaster)
	ghdl -a $(bram_dp_write_through)
	ghdl -a $(axis_data_fifo)
	ghdl -a $(spi_master)
	ghdl -e spi_master_tb;
	ghdl -r spi_master_tb --stop-time=80us --vcd=spi_wave.vcd;
	gtkwave spi_wave.vcd;

sim_w5500: 
	ghdl -a $(bram_dp_write_through);
	ghdl -a $(testbench_w5500)
	ghdl -a $(top_for_tb_w5500);
	ghdl -a $(fsm);
	ghdl -a $(external_data_handler);
	ghdl -a $(spi_master);
	ghdl -a $(axis_data_fifo);
	ghdl -a $(data_streamer);
	ghdl -a $(stream_manager);
	ghdl -e tb_top_w5500;
	ghdl -r tb_top_w5500 --stop-time=700us --vcd=wave.vcd;
	gtkwave wave.vcd;

sim_dc:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(interlock_glitch_filter)
	ghdl -a --std=08 $(data_concentrator_testbench)
	ghdl -a --std=08 $(metric_packet_fifo)
	ghdl -a --std=08 $(priority_axis_data_fifo)
	ghdl -a --std=08 $(data_concentrator)
	ghdl -a --std=08 $(udp_packet_adapter)
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(metric_packet_manager)
	ghdl -a --std=08 -frelaxed $(bram_threshold_lookup)
	ghdl -a --std=08 $(threshold_logic)
	ghdl -a --std=08 $(telemetry_sender)
	ghdl -e --std=08 -frelaxed data_concentrator_tb;
	ghdl -r --std=08 -frelaxed data_concentrator_tb --stop-time=20us --wave=wave_data_concentrator.ghw;
	gtkwave wave_data_concentrator.ghw my_sav.sav;

sim_all:
	ghdl -a $(metric_packet_stream_interface)
	ghdl -a $(tb_for_w5500_and_dc)
	ghdl -a $(top_for_tb_w5500_and_dc);
	ghdl -a $(fsm);
	ghdl -a $(external_data_handler);
	ghdl -a $(spi_master);
	ghdl -a $(priority_axis_data_fifo);
	ghdl -a $(axis_data_fifo);
	ghdl -a $(data_streamer);
	ghdl -a $(stream_manager);
	ghdl -a $(bram_dp_write_through);
	ghdl -a $(data_concentrator_testbench)
	ghdl -a $(metric_packet_fifo)
	ghdl -a $(data_concentrator)
	ghdl -a $(udp_packet_adapter)
	ghdl -a $(bram_dp_write_through)
	ghdl -a $(metric_packet_manager)
	ghdl -a $(bram_threshold_lookup)
	ghdl -a $(threshold_logic)
	ghdl -a $(interlock_glitch_filter)
	ghdl -a $(telemetry_sender)
	ghdl -e tb_top_w5500_and_dc;
	ghdl -r tb_top_w5500_and_dc --stop-time=200us --vcd=wave_data_concentrator.vcd;
	gtkwave wave_data_concentrator.vcd;

synth_w5500:
	yosys -m ghdl -p "ghdl -fexplicit --warn-no-binding --ieee=synopsys --std=08 -frelaxed $(top_w5500_file) $(fsm) $(external_data_handler) $(axis_data_fifo) $(stalling_axis_data_fifo) $(spi_master) $(data_streamer) $(stream_manager) $(bram_dp_write_through) -e top_w5500; synth_gatemate -top top_w5500 -vlog $(verilog_net_export) -nomx8 -luttree; write_json $(design_json_export)"

synth_w5500_and_dc:
	yosys -m ghdl -p "ghdl -fexplicit --warn-no-binding --ieee=synopsys --std=08 -frelaxed $(top_file) $(fsm) $(external_data_handler) $(spi_master) $(axis_data_fifo) $(data_streamer) $(stream_manager) $(bram_dp_write_through) $(metric_packet_stream_interface) $(metric_packet_fifo) $(priority_axis_data_fifo) $(data_concentrator) $(udp_packet_adapter) $(bram_dp_write_through) $(metric_packet_manager) $(bram_threshold_lookup) $(threshold_logic) $(interlock_glitch_filter) $(telemetry_sender) -e top; synth_gatemate -top top -nomx8 -luttree; write_json $(design_json_export)"


impl:
	nextpnr-himbaechel --device=CCGM1A1 --json $(design_json_export) -o ccf=$(constraints_file_all) -o out=$(impl_file) --router router2 --router2-tmg-ripup -o fpga_mode=speed --routed-svg routed.svg --placed-svg placed.svg --parallel-refine --threads 4


impl_w5500:
	nextpnr-himbaechel --device=CCGM1A1 --json $(design_json_export) -o ccf=$(constraints_file_w5500) -o out=$(impl_file) --router router2 -o fpga_mode=speed


gmpack:
	gmpack --input $(impl_file) --bit $(bit_file) --crcmode=check --spimode=quad

upload_jtag:
	openFPGALoader -b gatemate_evb_jtag $(bit_file) --freq 15000000

upload_spi:
	openFPGALoader -b gatemate_evb_spi $(bit_file) --freq 15000000

clean:
	rm -f $(bit_file)
	rm -f *.o
	rm -f $(design_json_export)
	rm -f $(impl_file) 
	rm -f $(verilog_net_export)

w5500_all:
	make clean
	make synth_w5500;
	make impl_w5500;
	make gmpack;
	make upload_spi;

all:
	make clean
	make synth_w5500_and_dc;
	make impl;
	make gmpack;
	make upload_spi;

custom_synth_gatemate:
	yosys -m ghdl -p "ghdl --warn-no-binding --ieee=synopsys --std=08 -frelaxed --latches $(top_file) $(fsm) $(external_data_handler) $(spi_master) $(axis_data_fifo) $(data_streamer) $(stream_manager) $(bram_dp_write_through) $(metric_packet_stream_interface) $(metric_packet_fifo) $(priority_axis_data_fifo) $(data_concentrator) $(udp_packet_adapter) $(metric_packet_manager) $(bram_threshold_lookup) $(threshold_logic) $(telemetry_sender) -e top; \
	proc; opt; opt_expr; opt_muxtree; opt_clean; \
	read_verilog -lib -specify +/gatemate/cells_sim.v +/gatemate/cells_bb.v; \
	hierarchy -check -top top ; \
	proc ; \
    flatten ; \
    tribuf -logic ; \
    deminout ; \
    opt_expr ; \
    opt_clean ; \
    check ; \
    opt -nodffe -nosdff ; \
    fsm ; \
    opt ; \
    wreduce ; \
    peepopt ; \
    opt_clean ; \
    muxpack ; \
    share ; \
    techmap -map +/cmp2lut.v -D LUT_WIDTH=4 ; \
    opt_expr ; \
    opt_clean ; \
	techmap -map +/gatemate/mul_map.v;\
    opt; \
    memory -nomap; \
    opt_clean; \
	memory_libmap -lib +/gatemate/brams.txt; \
	techmap -map +/gatemate/brams_map.v; \
	opt -fast -mux_undef -undriven -fine ; \
    memory_map; \
	opt -undriven -fine; \
	techmap -map +/techmap.v  -map +/gatemate/arith_map.v; \
    opt -fast; \
	iopadmap -bits -inpad CC_IBUF Y:I -outpad CC_OBUF A:O -toutpad CC_TOBUF ~T:A:O -tinoutpad CC_IOBUF ~T:Y:A:IO; \
    clean; \
	opt_clean; \
	dfflegalize -cell \$$_DFFE_????_ 01 -cell \$$_DLATCH_???_ 01; \
	techmap -map +/gatemate/reg_map.v; \
    opt_expr -mux_undef; \
    simplemap; \
    opt_clean; \
    opt -fast; \
    simplemap; \
    techmap -map +/gatemate/mux_map.v; \
	abc -genlib +/gatemate/lut_tree_cells.genlib; \
    techmap -map +/gatemate/lut_tree_map.v; \
    gatemate_foldinv; \
    techmap -map +/gatemate/inv_map.v; \
    clean; \
	techmap -map +/gatemate/lut_map.v; \
	clean; \
	clkbufmap -buf CC_BUFG O:I; \
    clean; \
	hierarchy -check; \
    stat -width; \
    check -noinit; \
    blackbox =A:whitebox; \
	opt_clean -purge; \
    write_verilog -noattr $(verilog_net_export); \
	write_json $(design_json_export)"
# 	yosys -p "read_verilog -lib -specify +/gatemate/cells_sim.v +/gatemate/cells_bb.v;"
# 	yosys -p "hierarchy -check -top top"
