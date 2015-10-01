-- Copyright (c) 2015 Nuand LLC
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library std;
    use std.env.all;

entity mm_driver is
    port(
        mm_clock        :   in  std_logic;
        mm_reset        :   in  std_logic;
        mm_rd_req       :   out std_logic;
        mm_wr_req       :   out std_logic;
        mm_addr         :   out std_logic_vector(7 downto 0);
        mm_wr_data      :   out std_logic_vector(7 downto 0);
        mm_rd_data      :   in  std_logic_vector(7 downto 0);
        mm_rd_datav     :   in  std_logic;
        mm_wait_req     :   in  std_logic;

        mm_irq          :   in  std_logic;

        tcxo_clock      :   out std_logic
    );
end entity;

architecture arch of mm_driver is

    function half_clk_per( freq : real ) return time is
    begin
        return ( (0.5 sec) / real(freq) );
    end function;

    constant TCXO_START_FREQ   : real    := 20.4e6;
    constant TCXO_TARGET_FREQ  : real    := 38.4e6;
    constant TCXO_INCR_FREQ    : real    := 1.0e6;

    -- FSM States
    type fsm_t is (
        RESET_COUNTERS,
        START_COUNTERS,
        ENABLE_IRQS,
        WAIT_FOR_IRQ,
        READ_COUNTS,
        FREQ_ADJUST,
        HOLDOFF,
        TERMINATE_SIMULATION
    );

    -- State of internal signals
    type state_t is record
        state           : fsm_t;
        holdoff_count   : natural;
        pps_1s_count    : std_logic_vector(63 downto 0);
        pps_10s_count   : std_logic_vector(63 downto 0);
        pps_100s_count  : std_logic_vector(63 downto 0);
        tcxo_half_per   : time;
        tcxo_freq       : real;
    end record;

    constant RESET_VALUE : state_t := (
        state           => RESET_COUNTERS,
        holdoff_count   => 0,
        pps_1s_count    => (others => '-'),
        pps_10s_count   => (others => '-'),
        pps_100s_count  => (others => '-'),
        tcxo_half_per   => half_clk_per( TCXO_START_FREQ ),
        tcxo_freq       => TCXO_START_FREQ
    );

    constant RESET_TIME  : natural := 50;
    constant DEAD_TIME   : natural := 1000;
    constant IRQ_TIMEOUT : natural := 20000;

    constant PPS_CNT_1S_ADDR   : natural := 0*8;
    constant PPS_CNT_10S_ADDR  : natural := 1*8;
    constant PPS_CNT_100S_ADDR : natural := 2*8;
    constant CONTROL_ADDR      : natural := 4*8;
    constant INTERRUPT_ADDR    : natural := 5*8;

    signal   tcxo_clock_i      : std_logic := '1';

    signal   current           : state_t := RESET_VALUE;
    signal   future            : state_t := RESET_VALUE;

begin

    tcxo_clock_i <= not tcxo_clock_i after current.tcxo_half_per;
    tcxo_clock   <= tcxo_clock_i;

    sync_proc : process( mm_clock, mm_reset )
    begin
        if( mm_reset = '1' ) then
            current <= RESET_VALUE;
        elsif( rising_edge(mm_clock) ) then
            current <= future;
        end if;
    end process;

    comb_proc : process( all )
    begin
        mm_rd_req   <= '0';
        mm_wr_req   <= '0';
        mm_addr     <= (others => '0');
        mm_wr_data  <= (others => '0');

        case (current.state) is
            when RESET_COUNTERS =>
                mm_wr_req  <= '1';
                mm_wr_data <= x"07";
                mm_addr    <= std_logic_vector(to_unsigned(CONTROL_ADDR,mm_addr'length));
                future.holdoff_count <= 0;
                future.state <= START_COUNTERS;

            when START_COUNTERS =>
                future.holdoff_count <= current.holdoff_count + 1;
                if( current.holdoff_count = RESET_TIME ) then
                    future.holdoff_count <= 0;
                    mm_wr_req  <= '1';
                    mm_wr_data <= x"00";
                    mm_addr    <= std_logic_vector(to_unsigned(CONTROL_ADDR,mm_addr'length));
                    future.state <= HOLDOFF;
                end if;

            when ENABLE_IRQS =>
                mm_wr_req <= '1';
                mm_wr_data <= x"01";
                mm_addr <= std_logic_vector(to_unsigned(INTERRUPT_ADDR,mm_addr'length));
                future.state <= WAIT_FOR_IRQ;

            when WAIT_FOR_IRQ =>
                if( mm_irq = '1' ) then
                    future.holdoff_count <= 0;
                    mm_wr_req <= '1';
                    mm_wr_data <= x"11"; -- clear and disable interrupts
                    mm_addr <= std_logic_vector(to_unsigned(INTERRUPT_ADDR,mm_addr'length));
                    --future.state <= READ_PPS_1S;
                    future.state <= READ_COUNTS;
                else
                    future.holdoff_count <= current.holdoff_count + 1;
                    if( current.holdoff_count = IRQ_TIMEOUT ) then
                        future.holdoff_count <= 0;
                        future.state <= TERMINATE_SIMULATION;
                    end if;
                end if;

            when READ_COUNTS =>
                future.holdoff_count <= current.holdoff_count + 1;
                mm_rd_req <= '1';
                if( current.holdoff_count < 8 ) then
                    mm_addr <= std_logic_vector(to_unsigned(PPS_CNT_1S_ADDR+(current.holdoff_count mod 8),mm_addr'length));
                    future.pps_1s_count <= mm_rd_data &
                                           current.pps_1s_count(current.pps_1s_count'left downto
                                                                current.pps_1s_count'right+mm_rd_data'length);
                elsif( current.holdoff_count < 16 ) then
                    -- Need to shift in the last byte of data from previous count
                    if( current.holdoff_count = 8 ) then
                        future.pps_1s_count <= mm_rd_data &
                                               current.pps_1s_count(current.pps_1s_count'left downto
                                                                    current.pps_1s_count'right+mm_rd_data'length);
                    end if;
                    -- Also start capturing the next counter value
                    mm_addr <= std_logic_vector(to_unsigned(PPS_CNT_10S_ADDR+(current.holdoff_count mod 8),mm_addr'length));
                    future.pps_10s_count <= mm_rd_data &
                                            current.pps_10s_count(current.pps_10s_count'left downto
                                                                  current.pps_10s_count'right+mm_rd_data'length);
                elsif( current.holdoff_count < 24 ) then
                    -- Need to shift in the last byte of data from previous count
                    if( current.holdoff_count = 16 ) then
                        future.pps_10s_count <= mm_rd_data &
                                                current.pps_10s_count(current.pps_10s_count'left downto
                                                                      current.pps_10s_count'right+mm_rd_data'length);
                    end if;
                    -- Also start capturing the next counter value
                    mm_addr <= std_logic_vector(to_unsigned(PPS_CNT_100S_ADDR+(current.holdoff_count mod 8),mm_addr'length));
                    future.pps_100s_count <= mm_rd_data &
                                             current.pps_100s_count(current.pps_100s_count'left downto
                                                                    current.pps_100s_count'right+mm_rd_data'length);
                else
                    -- Need to shift in the last byte of data from previous count
                    if( current.holdoff_count = 24 ) then
                        future.pps_100s_count <= mm_rd_data &
                                                 current.pps_100s_count(current.pps_100s_count'left downto
                                                                        current.pps_100s_count'right+mm_rd_data'length);
                    end if;
                    mm_rd_req <= '0';
                    future.holdoff_count <= 0;
                    future.state <= FREQ_ADJUST;
                end if;

            when FREQ_ADJUST =>
                future.tcxo_half_per <= half_clk_per(current.tcxo_freq+TCXO_INCR_FREQ);
                future.tcxo_freq     <= current.tcxo_freq + TCXO_INCR_FREQ;
                future.state <= HOLDOFF;

            when HOLDOFF =>
                future.holdoff_count <= current.holdoff_count + 1;
                if( current.holdoff_count = DEAD_TIME ) then
                    future.holdoff_count <= 0;
                    future.state <= ENABLE_IRQS;
                end if;

            when TERMINATE_SIMULATION =>
                --stop(0);
                null;

        end case;
    end process;

end architecture;
