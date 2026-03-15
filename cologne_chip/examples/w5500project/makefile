top_file=hdl/top.vhd
top_for_tb=hdl/top_for_tb.vhd
testbench=hdl/tb_top.vhd
fsm = hdl/w5500_state_machine.vhd
external_data_handler = hdl/ext_data_handler.vhd
txrx_unit = hdl/spi_master.vhd
custom_fifo = hdl/custom_fifo.vhd
data_streamer = hdl/spi_streamer.vhd
stream_manager = hdl/w5500_stream_manager.vhd

verilog_net_export = net/top_synth.v
design_json_export = design.json

constraints_file = hdl/w5500.ccf
impl_file = implementation.txt
bit_file = bitstream.bit

sim:
	ghdl -a $(testbench)
	ghdl -a $(top_for_tb);
	ghdl -a $(fsm);
	ghdl -a $(external_data_handler);
	ghdl -a $(txrx_unit);
	ghdl -a $(custom_fifo);
	ghdl -a $(data_streamer);
	ghdl -a $(stream_manager);
	ghdl -e tb_top;
	ghdl -r tb_top --stop-time=10us --vcd=wave.vcd;
	gtkwave wave.vcd;


synth:
	yosys -m ghdl -p "ghdl --warn-no-binding --ieee=synopsys --std=08 --latches $(top_file) $(fsm) $(external_data_handler) $(txrx_unit) $(custom_fifo) $(data_streamer) $(stream_manager) -e top; synth_gatemate -top top -vlog $(verilog_net_export)  -nomx8 -luttree; write_json  $(design_json_export)"

impl:
	nextpnr-himbaechel --device=CCGM1A1 --json $(design_json_export) -o ccf=$(constraints_file) -o out=$(impl_file) --router router2

gmpack:
	gmpack --input $(impl_file) --bit $(bit_file) --spimode=quad --crcmode=check

upload_jtag:
	openFPGALoader -b gatemate_evb_jtag $(bit_file)

upload_spi:
	openFPGALoader -b gatemate_evb_spi $(bit_file)

all:
	make synth;
	make impl;
	make gmpack;
	make upload_jtag;
