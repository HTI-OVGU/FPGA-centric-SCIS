-- The data concentrator's two FIFOs under randomised backpressure.
--
-- priority_fifo and metric_packet_fifo are copies of axis_data_fifo and carry
-- the same three defects, so they get the same test: random stalls on both
-- sides, checked at the FIFO's own pins, every accepted write queued and every
-- accepted read matched against the head of that queue.
--
-- This is the path that produced the corruption seen on the board: the metric
-- source starves while the state machine is always ready, which is precisely
-- the combination that broke. A byte repeated fifteen to thirty times inside a
-- record, or a record missing its leading 'V', both come from here.
--
-- Both FIFOs are driven at once from independent patterns, so one run covers
-- them both.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_dc_fifo_stress is
  generic (
    G_WORDS    : integer := 4000;
    G_WR_STALL : integer := 3;
    G_RD_STALL : integer := 0
  );
end entity;

architecture sim of tb_dc_fifo_stress is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- priority_axis_data_fifo
  signal p_s_tvalid : std_logic := '0';
  signal p_s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal p_s_tlast  : std_logic := '0';
  signal p_s_tready : std_logic;
  signal p_m_tvalid : std_logic;
  signal p_m_tdata  : std_logic_vector(7 downto 0);
  signal p_m_tlast  : std_logic;
  signal p_m_tready : std_logic := '0';
  signal p_af       : std_logic;

  -- metric_packet_fifo
  signal q_s_tvalid : std_logic := '0';
  signal q_s_tdata  : std_logic_vector(7 downto 0) := (others => '0');
  signal q_s_tlast  : std_logic := '0';
  signal q_s_tready : std_logic;
  signal q_s_tuser  : std_logic_vector(2 downto 0) := "000";
  signal q_m_tvalid : std_logic;
  signal q_m_tdata  : std_logic_vector(7 downto 0);
  signal q_m_tlast  : std_logic;
  signal q_m_tready : std_logic := '0';
  signal q_m_tuser  : std_logic_vector(2 downto 0);

  signal p_written, p_read, p_wrong : integer := 0;
  signal q_written, q_read, q_wrong : integer := 0;
  signal wr_done : std_logic := '0';

  function lfsr_next(v : unsigned(15 downto 0)) return unsigned is
  begin
    return v(14 downto 0) & (v(15) xor v(13) xor v(12) xor v(10));
  end function;
begin

  clk <= not clk after 5 ns;

  u_prio : entity work.priority_axis_data_fifo
    generic map (g_WIDTH => 10, g_DEPTH => 1023)
    port map (
      i_clk => clk, i_rst_sync => rst,
      s_axis_tvalid => p_s_tvalid, s_axis_tdata => p_s_tdata,
      s_axis_tlast => p_s_tlast, s_axis_tready => p_s_tready,
      m_axis_tvalid => p_m_tvalid, m_axis_tdata => p_m_tdata,
      m_axis_tlast => p_m_tlast, m_axis_tready => p_m_tready,
      almost_full => p_af);

  u_mpf : entity work.metric_packet_fifo
    generic map (g_WIDTH => 20, g_DEPTH => 1023)
    port map (
      i_clk => clk, i_rst_sync => rst,
      s_axis_tvalid => q_s_tvalid, s_axis_tdata => q_s_tdata,
      s_axis_tlast => q_s_tlast, s_axis_tready => q_s_tready,
      s_axis_tuser => q_s_tuser,
      m_axis_tvalid => q_m_tvalid, m_axis_tdata => q_m_tdata,
      m_axis_tlast => q_m_tlast, m_axis_tready => q_m_tready,
      m_axis_tuser => q_m_tuser);

  writers : process
    variable rnd : unsigned(15 downto 0) := x"ACE1";
    variable i   : integer := 0;
  begin
    wait for 100 ns;
    wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    while i < G_WORDS loop
      rnd := lfsr_next(rnd);
      if to_integer(rnd(2 downto 0)) < G_WR_STALL then
        p_s_tvalid <= '0';
        q_s_tvalid <= '0';
        for k in 1 to 1 + to_integer(rnd(4 downto 3)) loop
          wait until rising_edge(clk);
        end loop;
      end if;

      p_s_tdata <= std_logic_vector(to_unsigned(i mod 256, 8));
      q_s_tdata <= std_logic_vector(to_unsigned(i mod 256, 8));
      if (i mod 9) = 8 then
        p_s_tlast <= '1';
        q_s_tlast <= '1';
      else
        p_s_tlast <= '0';
        q_s_tlast <= '0';
      end if;
      p_s_tvalid <= '1';
      q_s_tvalid <= '1';

      loop
        wait until rising_edge(clk);
        exit when p_s_tready = '1' and q_s_tready = '1';
      end loop;
      i := i + 1;
    end loop;

    p_s_tvalid <= '0';
    q_s_tvalid <= '0';
    p_s_tlast  <= '0';
    q_s_tlast  <= '0';
    wait for 5 us;
    wr_done <= '1';
    wait;
  end process;

  readers : process
    variable rnd : unsigned(15 downto 0) := x"1234";
  begin
    wait until rst = '0';
    loop
      rnd := lfsr_next(rnd);
      if to_integer(rnd(2 downto 0)) < G_RD_STALL then
        p_m_tready <= '0';
        q_m_tready <= '0';
        for k in 1 to 1 + to_integer(rnd(4 downto 3)) loop
          wait until rising_edge(clk);
        end loop;
      end if;
      p_m_tready <= '1';
      q_m_tready <= '1';
      wait until rising_edge(clk);
    end loop;
  end process;

  monitor : process
    type q_t is array (0 to 8191) of integer;
    variable pq : q_t := (others => 0);
    variable qq : q_t := (others => 0);
    variable ph, pt, qh, qt : integer := 0;
    variable got : integer;
  begin
    wait until rst = '0';
    loop
      wait until rising_edge(clk);

      if p_s_tvalid = '1' and p_s_tready = '1' then
        pq(pt mod 8192) := to_integer(unsigned(p_s_tdata));
        pt := pt + 1;
        p_written <= pt;
      end if;
      if p_m_tvalid = '1' and p_m_tready = '1' then
        got := to_integer(unsigned(p_m_tdata));
        if ph >= pt or got /= pq(ph mod 8192) then
          if p_wrong < 4 then
            report "priority_fifo read " & integer'image(ph) & ": got "
                 & integer'image(got) severity warning;
          end if;
          p_wrong <= p_wrong + 1;
        end if;
        ph := ph + 1;
        p_read <= ph;
      end if;

      if q_s_tvalid = '1' and q_s_tready = '1' then
        qq(qt mod 8192) := to_integer(unsigned(q_s_tdata));
        qt := qt + 1;
        q_written <= qt;
      end if;
      if q_m_tvalid = '1' and q_m_tready = '1' then
        got := to_integer(unsigned(q_m_tdata));
        if qh >= qt or got /= qq(qh mod 8192) then
          if q_wrong < 4 then
            report "metric_packet_fifo read " & integer'image(qh) & ": got "
                 & integer'image(got) severity warning;
          end if;
          q_wrong <= q_wrong + 1;
        end if;
        qh := qh + 1;
        q_read <= qh;
      end if;
    end loop;
  end process;

  checker : process
  begin
    wait until wr_done = '1';
    wait for 300 us;
    report "=== tb_dc_fifo_stress  wr_stall=" & integer'image(G_WR_STALL)
         & " rd_stall=" & integer'image(G_RD_STALL) & " ===" severity note;
    report "priority_fifo      written " & integer'image(p_written)
         & "  read " & integer'image(p_read)
         & "  wrong " & integer'image(p_wrong) severity note;
    report "metric_packet_fifo written " & integer'image(q_written)
         & "  read " & integer'image(q_read)
         & "  wrong " & integer'image(q_wrong) severity note;
    assert p_read = p_written and p_wrong = 0
      report "priority_fifo BROKEN" severity error;
    assert q_read = q_written and q_wrong = 0
      report "metric_packet_fifo BROKEN" severity error;
    if p_read = p_written and p_wrong = 0
       and q_read = q_written and q_wrong = 0 then
      report "PASS" severity note;
    else
      report "FAIL" severity note;
    end if;
    finish;
  end process;

end architecture;
