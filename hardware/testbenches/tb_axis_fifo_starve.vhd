-- Does axis_data_fifo stop presenting data when it runs empty mid-stream?
--
-- burst_read_mode latches after two back-to-back reads and from then on the
-- output comes from prefetch_reg with m_axis_tvalid = prefetch_valid. Every
-- assignment that clears prefetch_valid is guarded by burst_read_mode = '0',
-- so in burst mode nothing retires the word: once the writer pauses, the FIFO
-- keeps asserting tvalid with the last word it fetched and the reader takes it
-- again on every clock.
--
-- This is the duplicate-byte source in the W5500 transmit path. The FIFO sits
-- in spi_streamer (payload) and in spi_master (payload), so a gap in the fabric
-- becomes extra bytes inside an open SPI transaction, which the W5500 writes
-- into its transmit buffer at auto-incremented addresses while Sn_TX_WR is
-- advanced only by the number of bytes the fabric actually handed over.
--
-- Write a burst, starve the FIFO, write the rest. The reader is always ready.
-- Everything written must come out exactly once, in order, and nothing may come
-- out while the FIFO is empty.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_axis_fifo_starve is
end entity;

architecture sim of tb_axis_fifo_starve is
  constant N_BEFORE : integer := 5;    -- words written back-to-back
  constant STARVE   : integer := 40;   -- clocks with the FIFO empty
  constant N_AFTER  : integer := 4;    -- words written after the gap
  constant N_TOTAL  : integer := N_BEFORE + N_AFTER;

  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal s_tvalid : std_logic := '0';
  signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_tlast  : std_logic := '0';
  signal s_tready : std_logic;
  signal m_tvalid : std_logic;
  signal m_tdata  : std_logic_vector(7 downto 0);
  signal m_tlast  : std_logic;
  signal m_tready : std_logic := '1';

  signal writes_done : std_logic := '0';
  signal n_read   : integer := 0;
  signal n_wrong  : integer := 0;
begin
  clk <= not clk after 5 ns;

  dut : entity work.axis_data_fifo
    generic map (g_WIDTH => 10, g_DEPTH => 2047)
    port map (
      i_clk => clk, i_rst_sync => rst,
      s_axis_tvalid => s_tvalid, s_axis_tdata => s_tdata,
      s_axis_tlast => s_tlast, s_axis_tready => s_tready,
      m_axis_tvalid => m_tvalid, m_axis_tdata => m_tdata,
      m_axis_tlast => m_tlast, m_axis_tready => m_tready);

  writer : process
    procedure put(v : integer; last : std_logic) is
    begin
      s_tdata  <= std_logic_vector(to_unsigned(v, 8));
      s_tlast  <= last;
      s_tvalid <= '1';
      loop
        wait until rising_edge(clk);
        exit when s_tready = '1';
      end loop;
      s_tvalid <= '0';
      s_tlast  <= '0';
    end procedure;
  begin
    wait for 100 ns;
    wait until rising_edge(clk);
    rst <= '0';
    wait for 100 ns;
    wait until rising_edge(clk);

    for i in 1 to N_BEFORE loop
      put(i, '0');
    end loop;

    for g in 1 to STARVE loop
      wait until rising_edge(clk);
    end loop;

    for i in N_BEFORE + 1 to N_TOTAL loop
      if i = N_TOTAL then
        put(i, '1');
      else
        put(i, '0');
      end if;
    end loop;

    wait for 500 ns;
    writes_done <= '1';
    wait;
  end process;

  reader : process
    variable expect : integer := 1;
    variable got    : integer;
  begin
    wait until rst = '0';
    loop
      wait until rising_edge(clk);
      if m_tvalid = '1' and m_tready = '1' then
        got := to_integer(unsigned(m_tdata));
        n_read <= n_read + 1;
        if got /= expect then
          if n_wrong < 8 then
            report "read " & integer'image(n_read + 1) & ": expected "
                 & integer'image(expect) & ", got " & integer'image(got)
              severity warning;
          end if;
          n_wrong <= n_wrong + 1;
        end if;
        if expect < N_TOTAL then
          expect := expect + 1;
        end if;
      end if;
    end loop;
  end process;

  checker : process
  begin
    wait until writes_done = '1';
    wait for 500 ns;
    report "=== tb_axis_fifo_starve ===" severity note;
    report "written: " & integer'image(N_TOTAL)
         & "   read: " & integer'image(n_read)
         & "   wrong: " & integer'image(n_wrong) severity note;
    assert n_read = N_TOTAL
      report "FIFO delivered " & integer'image(n_read) & " words for "
           & integer'image(N_TOTAL) & " written" severity error;
    assert n_wrong = 0
      report "FIFO delivered wrong data " & integer'image(n_wrong) & " times"
      severity error;
    if n_read = N_TOTAL and n_wrong = 0 then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;

end architecture;
