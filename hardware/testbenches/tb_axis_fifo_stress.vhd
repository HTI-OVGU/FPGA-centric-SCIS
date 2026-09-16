-- axis_data_fifo under randomised backpressure: does every word come out
-- exactly once, in order?
--
-- tb_axis_fifo_starve covers one specific hole (an empty FIFO re-presenting its
-- last word). This one hammers the handshake itself: the writer and the reader
-- each stall on a pseudo-random pattern, so the FIFO is driven through every
-- combination of full/empty, prefetch loaded/empty and back-to-back/one-shot
-- reads. A skid buffer that drops or repeats a word under any of those
-- combinations shows up here as a mismatch against the expected sequence.
--
-- Words are an 8-bit counter, so the check catches both loss and duplication:
-- the reader knows exactly which value must come next.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_axis_fifo_stress is
  generic (
    G_WORDS     : integer := 4000;
    G_WR_STALL  : integer := 3;   -- higher = writer pauses more
    G_RD_STALL  : integer := 3;   -- higher = reader pauses more
    -- How long each pause lasts. The first version of this bench only ever
    -- stalled for one to four clocks, which is why it missed the case the
    -- receive path actually sees: the data concentrator holds tready low for
    -- tens of clocks at a time while it arbitrates.
    G_WR_STALL_LEN : integer := 4;
    G_RD_STALL_LEN : integer := 4
  );
end entity;

architecture sim of tb_axis_fifo_stress is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal s_tvalid : std_logic := '0';
  signal s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal s_tlast  : std_logic := '0';
  signal s_tready : std_logic;

  signal m_tvalid : std_logic;
  signal m_tdata  : std_logic_vector(7 downto 0);
  signal m_tlast  : std_logic;
  signal m_tready : std_logic := '0';

  signal n_written : integer := 0;
  signal n_read    : integer := 0;
  signal n_wrong   : integer := 0;
  signal wr_done   : std_logic := '0';

  -- 16-bit LFSR, so both sides get a repeatable but uncorrelated pattern
  function lfsr_next(v : unsigned(15 downto 0)) return unsigned is
  begin
    return v(14 downto 0) & (v(15) xor v(13) xor v(12) xor v(10));
  end function;
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
    variable rnd : unsigned(15 downto 0) := x"ACE1";
    variable i   : integer := 0;
  begin
    wait for 100 ns;
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    while i < G_WORDS loop
      -- pause before offering the next word
      rnd := lfsr_next(rnd);
      if to_integer(rnd(2 downto 0)) < G_WR_STALL then
        s_tvalid <= '0';
        for k in 1 to 1 + (to_integer(rnd(4 downto 3)) * G_WR_STALL_LEN) / 4 loop
          wait until rising_edge(clk);
        end loop;
      end if;

      s_tdata  <= std_logic_vector(to_unsigned(i mod 256, 8));
      s_tvalid <= '1';
      if (i mod 9) = 8 then
        s_tlast <= '1';
      else
        s_tlast <= '0';
      end if;

      loop
        wait until rising_edge(clk);
        exit when s_tready = '1';
      end loop;
      i := i + 1;
    end loop;

    s_tvalid <= '0';
    s_tlast  <= '0';
    wait for 2 us;
    wr_done <= '1';
    wait;
  end process;

  reader : process
    variable rnd : unsigned(15 downto 0) := x"1234";
  begin
    wait until rst = '0';
    loop
      rnd := lfsr_next(rnd);
      if to_integer(rnd(2 downto 0)) < G_RD_STALL then
        m_tready <= '0';
        for k in 1 to 1 + (to_integer(rnd(4 downto 3)) * G_RD_STALL_LEN) / 4 loop
          wait until rising_edge(clk);
        end loop;
      end if;
      m_tready <= '1';
      wait until rising_edge(clk);
    end loop;
  end process;

  -- Both sides are watched at the FIFO's own pins, so nothing depends on what
  -- the driving processes believe they did: every accepted write is queued and
  -- every accepted read must match the head of that queue.
  monitor : process
    type q_t is array (0 to 8191) of integer;
    variable q     : q_t := (others => 0);
    variable head  : integer := 0;
    variable tail  : integer := 0;
    variable got   : integer;
  begin
    wait until rst = '0';
    loop
      wait until rising_edge(clk);
      if s_tvalid = '1' and s_tready = '1' then
        q(tail mod 8192) := to_integer(unsigned(s_tdata));
        tail := tail + 1;
        n_written <= tail;
      end if;
      if m_tvalid = '1' and m_tready = '1' then
        got := to_integer(unsigned(m_tdata));
        if head >= tail then
          n_wrong <= n_wrong + 1;
          if n_wrong < 6 then
            report "read " & integer'image(head) & " with nothing written: got "
                 & integer'image(got) severity warning;
          end if;
        elsif got /= q(head mod 8192) then
          if n_wrong < 6 then
            report "read " & integer'image(head) & ": expected "
                 & integer'image(q(head mod 8192)) & ", got " & integer'image(got)
              severity warning;
          end if;
          n_wrong <= n_wrong + 1;
        end if;
        head := head + 1;
        n_read <= head;
      end if;
    end loop;
  end process;

  checker : process
  begin
    wait until wr_done = '1';
    wait for 200 us;
    report "=== tb_axis_fifo_stress  wr_stall=" & integer'image(G_WR_STALL)
         & " rd_stall=" & integer'image(G_RD_STALL)
         & "  stall length up to " & integer'image(G_WR_STALL_LEN) & "/"
         & integer'image(G_RD_STALL_LEN) & " clks ===" severity note;
    report "written: " & integer'image(n_written)
         & "   read: " & integer'image(n_read)
         & "   wrong: " & integer'image(n_wrong) severity note;
    assert n_read = n_written
      report "COUNT MISMATCH: read " & integer'image(n_read) & " of "
           & integer'image(n_written) severity error;
    assert n_wrong = 0
      report "SEQUENCE BROKEN " & integer'image(n_wrong) & " times" severity error;
    if n_read = n_written and n_wrong = 0 then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;

end architecture;
