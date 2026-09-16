top_w5500_file=../../hdl/w5500/top_w5500.vhd
top_for_tb_w5500=../../testbenches/top_for_tb_w5500.vhd
testbench_w5500=../../testbenches/tb_top_w5500.vhd
fsm = ../../hdl/w5500/w5500_state_machine.vhd
external_data_handler = ../../hdl/w5500/ext_data_handler.vhd
spi_master = ../../hdl/w5500/spi_master.vhd
axis_data_fifo = ../../hdl/axis_data_fifo.vhd
data_streamer = ../../hdl/w5500/spi_streamer.vhd
stream_manager = ../../hdl/w5500/w5500_stream_manager.vhd
bram_dp_write_through = ../../hdl/bram_dp_write_through.vhd

metric_packet_stream_interface = ../../hdl/data_concentrator/metric_packet_stream_interface.vhd
threshold_tables_pkg = ../../hdl/data_concentrator/threshold_tables_pkg.vhd

metric_packet_fifo = ../../hdl/data_concentrator/metric_packet_fifo.vhd
priority_axis_data_fifo = ../../hdl/data_concentrator/priority_fifo.vhd
data_concentrator = ../../hdl/data_concentrator/data_concentrator.vhd
udp_packet_adapter = ../../hdl/data_concentrator/udp_packet_adapter.vhd
metric_packet_manager = ../../hdl/data_concentrator/metric_packet_manager.vhd
threshold_logic = ../../hdl/data_concentrator/threshold_logic.vhd 
bram_threshold_lookup = ../../hdl/data_concentrator/bram_threshold_lookup.vhd
telemetry_sender = ../../hdl/data_concentrator/telemetry_sender.vhd
interlock_glitch_filter = ../../hdl/data_concentrator/interlock_glitch_filter.vhd

data_concentrator_testbench = ../../testbenches/tb_data_concentrator.vhd

testbench_spimaster = ../../testbenches/tb_spimaster.vhd

# TOP FILE FOR BOTH W5500 and DataConcentrator (instead of external Data handler)
top_file = ../../hdl/top.vhd
top_for_tb_w5500_and_dc = ../../testbenches/top_for_w5500_and_dc_tb.vhd
tb_for_w5500_and_dc = ../../testbenches/tb_top_w5500_and_dc.vhd

# CAN metric channel (vendored under hardware/hdl/can/)
can_node_src       = ../../hdl/can/can_node.vhd
can_metric_adapter = ../../hdl/can/can_metric_adapter.vhd
can_metric_source  = ../../hdl/can/can_metric_source.vhd
tb_can_to_dc       = ../../testbenches/tb_can_to_dc.vhd
tb_can_ack         = ../../testbenches/tb_can_ack.vhd

# Telemetry-drain regression suite (layered: FIFO -> manager -> threshold ->
# composition -> telemetry -> full DC). Added while fixing the output-drain defect.
tb_dc_ch0_drain    = ../../testbenches/tb_dc_ch0_drain.vhd
tb_priority_fifo   = ../../testbenches/tb_priority_fifo.vhd
tb_mpf             = ../../testbenches/tb_mpf.vhd
tb_mpf_wrap        = ../../testbenches/tb_mpf_wrap.vhd
tb_threshold       = ../../testbenches/tb_threshold.vhd
tb_mpm             = ../../testbenches/tb_mpm.vhd
tb_thr_mgr         = ../../testbenches/tb_thr_mgr.vhd
tb_telemetry       = ../../testbenches/tb_telemetry.vhd

# W5500 transmit chain. tb_w5500_tx drives the real state machine, streamer and
# SPI master against a behavioural W5500 that decodes the header, keeps a
# register file and a transmit buffer, and publishes the datagram on SEND --
# so datagram content is checkable without the board. tb_axis_fifo_starve pins
# the duplicate-byte defect down on axis_data_fifo alone.
tb_w5500_tx        = ../../testbenches/tb_w5500_tx.vhd
tb_w5500_tx_multisocket = ../../testbenches/tb_w5500_tx_multisocket.vhd
tb_axis_fifo_starve = ../../testbenches/tb_axis_fifo_starve.vhd
tb_axis_fifo_stress = ../../testbenches/tb_axis_fifo_stress.vhd
tb_dc_w5500_tx      = ../../testbenches/tb_dc_w5500_tx.vhd
tb_dc_fifo_stress   = ../../testbenches/tb_dc_fifo_stress.vhd
tb_axis_fifo_depth  = ../../testbenches/tb_axis_fifo_depth.vhd
tb_w5500_rx_sustained = ../../testbenches/tb_w5500_rx_sustained.vhd
tb_w5500_tx_backpressure = ../../testbenches/tb_w5500_tx_backpressure.vhd

verilog_net_export = top_synth.v
design_json_export = design.json
# Written only by impl_repro -- see the comment there for why they must not be
# taken from a different nextpnr run than implementation.txt.
placed_json_export = placed.json
report_json_export = report.json
placed_svg_export  = placed.svg
routed_svg_export  = routed.svg
archive_dir        = ../../../etc/saved_bitsreams

constraints_file_w5500 = ../../hdl/w5500.ccf
constraints_file_all = ../../hdl/constraints_dc_and_w5500.ccf
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
	ghdl -a --std=08 $(threshold_tables_pkg)
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

sim_can_dc:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(threshold_tables_pkg)
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(metric_packet_fifo)
	ghdl -a --std=08 $(priority_axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(bram_threshold_lookup)
	ghdl -a --std=08 $(threshold_logic)
	ghdl -a --std=08 $(metric_packet_manager)
	ghdl -a --std=08 $(udp_packet_adapter)
	ghdl -a --std=08 $(interlock_glitch_filter)
	ghdl -a --std=08 $(telemetry_sender)
	ghdl -a --std=08 $(data_concentrator)
	ghdl -a --std=08 $(can_node_src)
	ghdl -a --std=08 $(can_metric_adapter)
	ghdl -a --std=08 $(can_metric_source)
	ghdl -a --std=08 $(tb_can_to_dc)
	ghdl -e --std=08 -frelaxed tb_can_to_dc
	ghdl -r --std=08 -frelaxed tb_can_to_dc --stop-time=600us --wave=wave_can_to_dc.ghw

view_can_dc:
	gtkwave wave_can_to_dc.ghw

sim_can_ack:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(can_node_src)
	ghdl -a --std=08 $(can_metric_adapter)
	ghdl -a --std=08 $(can_metric_source)
	ghdl -a --std=08 $(tb_can_ack)
	ghdl -e --std=08 -frelaxed tb_can_ack
	ghdl -r --std=08 -frelaxed tb_can_ack --stop-time=2ms --wave=wave_can_ack.ghw

view_can_ack:
	gtkwave wave_can_ack.ghw

sim_dc_drain:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(threshold_tables_pkg)
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(metric_packet_fifo)
	ghdl -a --std=08 $(priority_axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(bram_threshold_lookup)
	ghdl -a --std=08 $(threshold_logic)
	ghdl -a --std=08 $(metric_packet_manager)
	ghdl -a --std=08 $(udp_packet_adapter)
	ghdl -a --std=08 $(interlock_glitch_filter)
	ghdl -a --std=08 $(telemetry_sender)
	ghdl -a --std=08 $(data_concentrator)
	ghdl -a --std=08 $(tb_dc_ch0_drain)
	ghdl -e --std=08 -frelaxed tb_dc_ch0_drain
	ghdl -r --std=08 -frelaxed tb_dc_ch0_drain --stop-time=600us --wave=wave_dc_ch0_drain.ghw

# ---- Telemetry-drain regression suite (each isolates one stage of the output path) ----
sim_priority_fifo:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(priority_axis_data_fifo)
	ghdl -a --std=08 $(tb_priority_fifo)
	ghdl -e --std=08 -frelaxed tb_priority_fifo
	ghdl -r --std=08 -frelaxed tb_priority_fifo --stop-time=40us

sim_mpf:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(metric_packet_fifo)
	ghdl -a --std=08 $(tb_mpf)
	ghdl -e --std=08 -frelaxed tb_mpf
	ghdl -r --std=08 -frelaxed tb_mpf --stop-time=80us

sim_mpf_wrap:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(metric_packet_fifo)
	ghdl -a --std=08 $(tb_mpf_wrap)
	ghdl -e --std=08 -frelaxed tb_mpf_wrap
	ghdl -r --std=08 -frelaxed tb_mpf_wrap --stop-time=5ms

sim_axis_fifo_starve:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(tb_axis_fifo_starve)
	ghdl -e --std=08 -frelaxed tb_axis_fifo_starve
	ghdl -r --std=08 -frelaxed tb_axis_fifo_starve --stop-time=100us --ieee-asserts=disable

# Randomised backpressure on both sides of the FIFO, checked at its own pins.
# This is what caught the two ways the end-of-packet flush could drop the first
# byte of the next packet.
sim_axis_fifo_stress:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(tb_axis_fifo_stress)
	ghdl -e --std=08 -frelaxed tb_axis_fifo_stress
	@for c in "0 0" "3 0" "0 3" "3 3" "5 1" "1 5" "6 0" "0 6" "7 7"; do \
	  set -- $$c; printf 'wr_stall=%-3s rd_stall=%-3s ' $$1 $$2; \
	  ghdl -r --std=08 -frelaxed tb_axis_fifo_stress -gG_WR_STALL=$$1 \
	    -gG_RD_STALL=$$2 --stop-time=80ms --ieee-asserts=disable 2>&1 \
	    | grep -oE '(PASS|FAIL)' | tail -1; \
	done

# Does the FIFO hold the depth it advertises? Every instance asks for 2047 and
# the receive path pushes a whole 2 KB socket buffer through it in one go, so an
# address width that only reaches 1024 destroys the backlog underneath it.
sim_axis_fifo_depth:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(tb_axis_fifo_depth)
	ghdl -e --std=08 -frelaxed tb_axis_fifo_depth
	@for w in 800 1024 1200 1500 2040 2047; do \
	  printf 'write %-5s words ' $$w; \
	  ghdl -r --std=08 -frelaxed tb_axis_fifo_depth -gG_WRITE=$$w \
	    --stop-time=20ms --ieee-asserts=disable 2>&1 \
	    | grep -oE '(PASS|FAIL)' | tail -1; \
	done

# Sustained arrival into the chip's receive buffer, with the fabric applying
# backpressure the way the data concentrator does. This is the regime the board
# wedges in, and the one a stimulus that is always ready cannot reach.
sim_w5500_rx_sustained:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(spi_master)
	ghdl -a --std=08 -frelaxed $(data_streamer)
	ghdl -a --std=08 -frelaxed $(stream_manager)
	ghdl -a --std=08 -frelaxed $(fsm)
	ghdl -a --std=08 -frelaxed $(tb_w5500_rx_sustained)
	ghdl -e --std=08 -frelaxed tb_w5500_rx_sustained
	@for o in 0 16 64 256; do \
	  printf 'fabric stalls %-4s clks ' $$o; \
	  ghdl -r --std=08 -frelaxed tb_w5500_rx_sustained -gG_ARRIVAL_CLKS=1154 \
	    -gG_PACKETS=400 -gG_RREADY_OFF=$$o --stop-time=300ms \
	    --ieee-asserts=disable 2>&1 | grep -oE '(PASS|FAIL)' | tail -1; \
	done

# priority_fifo and metric_packet_fifo are copies of axis_data_fifo and carry
# the same defects, so they get the same randomised-backpressure test.
sim_dc_fifo_stress:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(metric_packet_fifo)
	ghdl -a --std=08 -frelaxed $(priority_axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(tb_dc_fifo_stress)
	ghdl -e --std=08 -frelaxed tb_dc_fifo_stress
	@for c in "0 0" "3 0" "0 3" "3 3" "5 1" "6 0" "7 7"; do \
	  set -- $$c; printf 'wr_stall=%-3s rd_stall=%-3s ' $$1 $$2; \
	  ghdl -r --std=08 -frelaxed tb_dc_fifo_stress -gG_WR_STALL=$$1 \
	    -gG_RD_STALL=$$2 --stop-time=80ms --ieee-asserts=disable 2>&1 \
	    | grep -oE '(PASS|FAIL)' | tail -1; \
	done

# The whole transmit chain with the real data concentrator as the source, which
# is what the hand-written stimulus in sim_w5500_tx could not reproduce.
sim_dc_w5500_tx:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(threshold_tables_pkg)
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(metric_packet_fifo)
	ghdl -a --std=08 -frelaxed $(priority_axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(bram_threshold_lookup)
	ghdl -a --std=08 -frelaxed $(threshold_logic)
	ghdl -a --std=08 -frelaxed $(metric_packet_manager)
	ghdl -a --std=08 -frelaxed $(udp_packet_adapter)
	ghdl -a --std=08 -frelaxed $(interlock_glitch_filter)
	ghdl -a --std=08 -frelaxed $(telemetry_sender)
	ghdl -a --std=08 -frelaxed $(data_concentrator)
	ghdl -a --std=08 -frelaxed $(spi_master)
	ghdl -a --std=08 -frelaxed $(data_streamer)
	ghdl -a --std=08 -frelaxed $(stream_manager)
	ghdl -a --std=08 -frelaxed $(fsm)
	ghdl -a --std=08 -frelaxed $(tb_dc_w5500_tx)
	ghdl -e --std=08 -frelaxed tb_dc_w5500_tx
	@for g in 300 60 20 0; do \
	  printf 'gap=%-4s ' $$g; \
	  ghdl -r --std=08 -frelaxed tb_dc_w5500_tx -gG_BATCH=16 -gG_N=60 \
	    -gG_GAP=$$g --stop-time=80ms --ieee-asserts=disable 2>&1 \
	    | grep -oE '(PASS|FAIL)' | tail -1; \
	done

# The wedge documented in README: a completely full 2 KB receive buffer makes
# Sn_RX_RSR read 2048, which used to be truncated to eleven bits and came back
# as zero, so the socket was skipped and never read again. The sweep steps
# across the boundary; 2049 works either way, which is what shows this is a
# truncation and not a size limit. The second block drives the watchdog
# threshold below the 1.1 ms buffer read on purpose, so the escape path itself
# is exercised: the machine must abort, retry and stay live.
sim_w5500_rx_full:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(spi_master)
	ghdl -a --std=08 -frelaxed $(data_streamer)
	ghdl -a --std=08 -frelaxed $(stream_manager)
	ghdl -a --std=08 -frelaxed $(fsm)
	ghdl -a --std=08 -frelaxed $(tb_w5500_tx)
	ghdl -e --std=08 -frelaxed tb_w5500_tx
	@for f in 1700 2040 2047 2048 2049; do \
	  printf 'Sn_RX_RSR=%-5s ' $$f; \
	  ghdl -r --std=08 -frelaxed tb_w5500_tx -gG_PACKETS=0 -gG_RX_FILL=$$f \
	    --stop-time=60ms --ieee-asserts=disable 2>&1 \
	    | grep -oE '(PASS|FAIL)' | tail -1; \
	done
	@for w in 65535 2000 600; do \
	  printf 'watchdog=%-6s ' $$w; \
	  ghdl -r --std=08 -frelaxed tb_w5500_tx -gG_PACKETS=0 -gG_RX_FILL=2048 \
	    -gG_WATCHDOG=$$w --stop-time=60ms --ieee-asserts=disable 2>&1 \
	    | grep -oE '(PASS|FAIL)' | tail -1; \
	done

# Sweeps batch depth against the two source timings that break the transmit
# chain: back-to-back packets and a stall inside a packet, the latter being what
# starves an already-open SPI transaction.
sim_w5500_tx:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(spi_master)
	ghdl -a --std=08 -frelaxed $(data_streamer)
	ghdl -a --std=08 -frelaxed $(stream_manager)
	ghdl -a --std=08 -frelaxed $(fsm)
	ghdl -a --std=08 -frelaxed $(tb_w5500_tx)
	ghdl -e --std=08 -frelaxed tb_w5500_tx
	@for b in 1 4 16; do \
	  for st in 0 3 250; do \
	    printf 'batch=%-3s stall=%-4s ' $$b $$st; \
	    ghdl -r --std=08 -frelaxed tb_w5500_tx -gG_BATCH=$$b -gG_PACKETS=40 \
	      -gG_STALL=$$st -gG_RX_PACKETS=8 --stop-time=80ms \
	      --ieee-asserts=disable 2>&1 | grep -oE '(PASS|FAIL)' | tail -1; \
	  done; \
	done

# Batching against socket interleave, which sim_w5500_tx cannot see because it
# drives socket 0 alone. The datagram being accumulated used to be tracked once
# rather than per socket, so a packet for a different socket closed it: traffic
# spread over the eight sockets sent one metric per datagram and paid the full
# nine-transaction SEND overhead every time, which is why the spread measured
# slower than one hot socket. The socket count is swept because the defect
# scales with it -- at one socket the old and new behaviour are identical.
sim_w5500_tx_multisocket:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(spi_master)
	ghdl -a --std=08 -frelaxed $(data_streamer)
	ghdl -a --std=08 -frelaxed $(stream_manager)
	ghdl -a --std=08 -frelaxed $(fsm)
	ghdl -a --std=08 -frelaxed $(tb_w5500_tx_multisocket)
	ghdl -e --std=08 -frelaxed tb_w5500_tx_multisocket
	@for s in 1 2 4 8; do \
	  for st in 0 3; do \
	    printf 'sockets=%-3s stall=%-4s ' $$s $$st; \
	    ghdl -r --std=08 -frelaxed tb_w5500_tx_multisocket -gG_SOCKETS=$$s \
	      -gG_BATCH=16 -gG_PACKETS=256 -gG_STALL=$$st --stop-time=80ms \
	      --ieee-asserts=disable 2>&1 | grep -oE '(PASS|FAIL)' | tail -1; \
	  done; \
	done
	@for s in 2 4 8; do \
	  printf 'starve sockets=%-3s ' $$s; \
	  ghdl -r --std=08 -frelaxed tb_w5500_tx_multisocket -gG_SOCKETS=$$s \
	    -gG_BATCH=16 -gG_PACKETS=256 -gG_STARVE=1 --stop-time=80ms \
	    --ieee-asserts=disable 2>&1 | grep -oE '(PASS|FAIL)' | tail -1; \
	done

# Transmit-buffer backpressure: can CHECK_IF_FREE_SIZE_IS_AVAILABLE livelock?
#
# It has no way out. Below minimum_free_tx_buffer_memory (256) it returns to
# GET_TX_FREE_BUFFER_SIZE (w5500_state_machine.vhd:816) and re-reads the same
# socket -- no retry budget, no socket advance, no fall-through to receive. And
# p_watchdog (:390) zeroes on every state change, so a two-state alternation
# never reaches WATCHDOG_CLKS: the watchdog detects a stuck state, not stalled
# progress.
#
# tb_w5500_tx cannot show this because its chip frees the whole buffer the
# instant SEND is written, so Sn_TX_FSR is never low. Here in-flight bytes keep
# occupying the buffer until the wire has carried them, as the chip does, and
# G_TX_FIXED_NS sets how fast that is. 5000 ns/datagram is the honest 100 Mbit
# figure; the livelock needs roughly 200000, i.e. a link ~40x degraded -- which
# is why the bench has never produced it and why this is a simulation result.
#
# G_DRAIN=0 reproduces tb_w5500_tx's instant-free model in the same sweep, so
# the "why was this not caught" column is in the output rather than in a claim.
sim_w5500_tx_backpressure:
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 -frelaxed $(axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(spi_master)
	ghdl -a --std=08 -frelaxed $(data_streamer)
	ghdl -a --std=08 -frelaxed $(stream_manager)
	ghdl -a --std=08 -frelaxed $(fsm)
	ghdl -a --std=08 -frelaxed $(tb_w5500_tx_backpressure)
	ghdl -e --std=08 -frelaxed tb_w5500_tx_backpressure
	@for ns in 5000 100000 200000 1000000; do \
	  printf 'wire=%-8s drain=1 ' $$ns; \
	  ghdl -r --std=08 -frelaxed tb_w5500_tx_backpressure -gG_BATCH=16 \
	    -gG_PACKETS=400 -gG_TX_FIXED_NS=$$ns -gG_DRAIN=1 -gG_RUN_US=40000 \
	    --stop-time=120ms --ieee-asserts=disable 2>&1 \
	    | grep -oE 'RESULT=[A-Z-]+' | tail -1; \
	done
	@printf 'wire=1000000 drain=0 (tb_w5500_tx model) '
	@ghdl -r --std=08 -frelaxed tb_w5500_tx_backpressure -gG_BATCH=16 \
	  -gG_PACKETS=400 -gG_TX_FIXED_NS=1000000 -gG_DRAIN=0 -gG_RUN_US=40000 \
	  --stop-time=120ms --ieee-asserts=disable 2>&1 \
	  | grep -oE 'RESULT=[A-Z-]+' | tail -1
	@printf 'txbuf=256 (free can never exceed the threshold) '
	@ghdl -r --std=08 -frelaxed tb_w5500_tx_backpressure -gG_BATCH=16 \
	  -gG_PACKETS=400 -gG_TX_FIXED_NS=100000 -gG_DRAIN=1 -gG_TXBUF=256 \
	  -gG_RUN_US=40000 --stop-time=120ms --ieee-asserts=disable 2>&1 \
	  | grep -oE 'RESULT=[A-Z-]+' | tail -1

sim_mpm:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(priority_axis_data_fifo)
	ghdl -a --std=08 $(metric_packet_manager)
	ghdl -a --std=08 $(tb_mpm)
	ghdl -e --std=08 -frelaxed tb_mpm
	ghdl -r --std=08 -frelaxed tb_mpm --stop-time=40us

sim_threshold:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(threshold_tables_pkg)
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(metric_packet_fifo)
	ghdl -a --std=08 -frelaxed $(bram_threshold_lookup)
	ghdl -a --std=08 $(threshold_logic)
	ghdl -a --std=08 $(tb_threshold)
	ghdl -e --std=08 -frelaxed tb_threshold
	ghdl -r --std=08 -frelaxed tb_threshold --stop-time=40us

sim_thr_mgr:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(threshold_tables_pkg)
	ghdl -a --std=08 -frelaxed $(bram_dp_write_through)
	ghdl -a --std=08 $(metric_packet_fifo)
	ghdl -a --std=08 $(priority_axis_data_fifo)
	ghdl -a --std=08 -frelaxed $(bram_threshold_lookup)
	ghdl -a --std=08 $(threshold_logic)
	ghdl -a --std=08 $(metric_packet_manager)
	ghdl -a --std=08 $(tb_thr_mgr)
	ghdl -e --std=08 -frelaxed tb_thr_mgr
	ghdl -r --std=08 -frelaxed tb_thr_mgr --stop-time=40us

sim_telemetry:
	ghdl -a --std=08 $(metric_packet_stream_interface)
	ghdl -a --std=08 $(telemetry_sender)
	ghdl -a --std=08 $(tb_telemetry)
	ghdl -e --std=08 -frelaxed tb_telemetry
	ghdl -r --std=08 -frelaxed tb_telemetry --stop-time=20us

sim_drain_suite: sim_w5500_tx_backpressure sim_priority_fifo sim_mpf sim_mpf_wrap sim_threshold sim_mpm sim_thr_mgr sim_telemetry sim_dc_drain sim_axis_fifo_starve sim_axis_fifo_stress sim_axis_fifo_depth sim_w5500_rx_sustained sim_dc_fifo_stress sim_w5500_tx sim_w5500_tx_multisocket sim_w5500_rx_full sim_dc_w5500_tx
	@echo "=== telemetry-drain suite complete ==="

sim_all:
	ghdl -a $(metric_packet_stream_interface)
	ghdl -a $(threshold_tables_pkg)
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
# 	yosys -m ghdl -p "ghdl -fexplicit --warn-no-binding --ieee=synopsys --std=08 -frelaxed $(top_w5500_file) $(fsm) $(external_data_handler) $(axis_data_fifo) $(spi_master) $(data_streamer) $(stream_manager) $(bram_dp_write_through) -e top_w5500; synth_gatemate -top top_w5500 -vlog $(verilog_net_export) -nomx8 -luttree; write_json $(design_json_export)"
	yosys -m ghdl -p "ghdl -fexplicit --warn-no-binding --ieee=synopsys --std=08 -frelaxed $(top_w5500_file) $(fsm) $(external_data_handler) $(axis_data_fifo) $(spi_master) $(data_streamer) $(stream_manager) $(bram_dp_write_through) -e top_w5500; synth_gatemate -top top_w5500 -vlog $(verilog_net_export); write_json $(design_json_export)"

synth_w5500_and_dc:
	yosys -m ghdl -p "ghdl -fexplicit --warn-no-binding --ieee=synopsys --std=08 -frelaxed $(top_file) $(fsm) $(external_data_handler) $(spi_master) $(axis_data_fifo) $(data_streamer) $(stream_manager) $(bram_dp_write_through) $(metric_packet_stream_interface) $(threshold_tables_pkg) $(metric_packet_fifo) $(priority_axis_data_fifo) $(data_concentrator) $(udp_packet_adapter) $(bram_dp_write_through) $(metric_packet_manager) $(bram_threshold_lookup) $(threshold_logic) $(interlock_glitch_filter) $(telemetry_sender) $(can_node_src) $(can_metric_adapter) $(can_metric_source) -e top; synth_gatemate -top top -nomx8 -luttree; setundef -init -zero -params; write_json $(design_json_export)"
# 	yosys -m ghdl -p "ghdl -fexplicit --warn-no-binding --ieee=synopsys --std=08 -frelaxed $(top_file) $(fsm) $(external_data_handler) $(spi_master) $(axis_data_fifo) $(data_streamer) $(stream_manager) $(bram_dp_write_through) $(metric_packet_stream_interface) $(threshold_tables_pkg) $(metric_packet_fifo) $(priority_axis_data_fifo) $(data_concentrator) $(udp_packet_adapter) $(bram_dp_write_through) $(metric_packet_manager) $(bram_threshold_lookup) $(threshold_logic) $(interlock_glitch_filter) $(telemetry_sender) $(can_node_src) $(can_metric_adapter) $(can_metric_source) -e top; synth_gatemate -top top; setundef -init -zero -params; write_json $(design_json_export)"

impl:
	nextpnr-himbaechel --device=CCGM1A1 --json $(design_json_export) -o ccf=$(constraints_file_all) -o out=$(impl_file) --router router2 --parallel-refine --threads 4 -o fpga_mode=speed --seed 3

# Same design, but reproducible and provenance-complete.
#
# --parallel-refine is dropped on purpose: it is nondeterministic, so a re-run
# at the same --seed produces a different placement (18,242 of 216,626 lines of
# implementation.txt differ, measured). That is fine for shipping but fatal for
# a figure, because nothing then ties the picture to the bitstream.
#
# The three extra outputs all come from THIS invocation, which is the whole
# point -- placed.json is the only file that carries cell names, and it is only
# valid for the implementation.txt written beside it:
#   --write   placed.json  netlist + NEXTPNR_BEL per cell (source-module panel)
#   --report  report.json  utilisation + timing (independent cross-check)
impl_repro:
	nextpnr-himbaechel --device=CCGM1A1 --json $(design_json_export) -o ccf=$(constraints_file_all) -o out=$(impl_file) --write $(placed_json_export) --report $(report_json_export) --router router2 -o fpga_mode=speed --seed 3

# nextpnr's own device-view renderer -- the official image, drawn by the place
# and route tool itself rather than by anything in figures/. Every bel on the
# die is emitted as a rect: unused ones outlined grey, used ones filled.
#
# Split out from impl_repro because the two SVGs are ~17 MB each and are not
# wanted on every build. Being deterministic, this re-run reproduces the same
# implementation.txt, so the SVGs describe the archived bitstream -- verify
# that rather than assuming it:
#   cmp implementation.txt ../../../etc/saved_bitsreams/<tag>/implementation.txt
impl_svg:
	nextpnr-himbaechel --device=CCGM1A1 --json $(design_json_export) -o ccf=$(constraints_file_all) -o out=$(impl_file) --placed-svg $(placed_svg_export) --routed-svg $(routed_svg_export) --router router2 -o fpga_mode=speed --seed 3

# Archive one build as an inseparable set. Splitting these up is what made the
# v1.13 bitstream unfigurable: implementation.txt and bitstream.bit were kept,
# placed.json was not, and the run that produced them cannot be replayed.
archive_build:
	@test -n "$(TAG)" || { echo "usage: make archive_build TAG=v1.14"; exit 1; }
	mkdir -p $(archive_dir)/$(TAG)
	cp $(impl_file) $(bit_file) $(report_json_export) $(design_json_export) $(archive_dir)/$(TAG)/
# placed.json is 52 MB of netlist and compresses ~12x; the figure script reads
# the .gz directly, so there is no reason to keep it expanded in the repo.
	gzip -9 -c $(placed_json_export) > $(archive_dir)/$(TAG)/placed.json.gz
# The nextpnr SVGs, if impl_svg was run: 17 MB each, ~34x smaller packed.
	for s in $(placed_svg_export) $(routed_svg_export); do \
	    test -f $$s && gzip -9 -c $$s > $(archive_dir)/$(TAG)/$$s.gz || true; \
	done
	cd $(archive_dir)/$(TAG) && md5sum $$(ls implementation.txt bitstream.bit placed.json.gz report.json design.json *.svg.gz 2>/dev/null) > MANIFEST.md5
	@echo "archived $(TAG):"; ls -la $(archive_dir)/$(TAG)


impl_w5500:
	nextpnr-himbaechel --device=CCGM1A1 --json $(design_json_export) -o ccf=$(constraints_file_w5500) -o out=$(impl_file) --router router2 -o fpga_mode=speed

gmpack_opts := $(shell gmpack --help 2>&1 | grep -q -e '--crcmode' && echo --crcmode=check --spimode=quad)

gmpack:
	gmpack --input $(impl_file) --bit $(bit_file) $(gmpack_opts)
# 	gmpack --input $(impl_file) --bit $(bit_file) --crcmode=check --spimode=quad
# 	gmpack --input $(impl_file) --bit $(bit_file) --crcmode=check --spimode=single
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
	yosys -m ghdl -p "ghdl --warn-no-binding --ieee=synopsys --std=08 -frelaxed --latches $(top_file) $(fsm) $(external_data_handler) $(spi_master) $(axis_data_fifo) $(data_streamer) $(stream_manager) $(bram_dp_write_through) $(metric_packet_stream_interface) $(threshold_tables_pkg) $(metric_packet_fifo) $(priority_axis_data_fifo) $(data_concentrator) $(udp_packet_adapter) $(metric_packet_manager) $(bram_threshold_lookup) $(threshold_logic) $(telemetry_sender) $(can_node_src) $(can_metric_adapter) $(can_metric_source) -e top; \
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

