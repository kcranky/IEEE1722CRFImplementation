-- Filename: 
--   top.vhd

-- Description:
--   Top level module for the IEEE 1722 CRF Implementation

-- Author:
--  Keegan Crankshaw
--  Original Intel TSE IP instantiation by industry partner

-- Date: 
--   December 2020

-- Available on GitHub: 
--   https://github.com/kcranky/IEEE1722CRFImplementation

-- Licence: 
--   MIT
--   https://github.com/kcranky/IEEE1722CRFImplementation/blob/main/LICENSE

library ieee;
use ieee.std_logic_1164.all;

entity top is
	port (
		-- source osc
		osc25 : in std_logic;
		
		gb_nrst : out std_logic_vector(1 downto 0);
		gb_mdio : inout std_logic;
		gb_mdc : out std_logic;
		
		-- Ethernet config
		g0_rx_clk : in std_logic;
		g0_rx_dv : in std_logic;
		g0_rx_d : in std_logic_vector(3 downto 0);
		g0_tx_clk : out std_logic;
		g0_tx_en : out std_logic;
		g0_tx_d : out std_logic_vector(3 downto 0);
		
		g1_rx_clk : in std_logic;
		g1_rx_dv : in std_logic;
		g1_rx_d : in std_logic_vector(3 downto 0);
		g1_tx_clk : out std_logic;
		g1_tx_en : out std_logic;
		g1_tx_d : out std_logic_vector(3 downto 0);
		
		-- LEDs
		fpgaled : out std_logic;
		statusled : out std_logic;
	
		ref_mck : out std_logic;
		ref_fs : out std_logic;
		ref_bck : out std_logic;

		rx_mck : out std_logic;
		rx_fs : out std_logic;
		rx_bck : out std_logic;

		rsvd1 : in std_logic;
		rsvd2 : in std_logic;

		fin : in std_logic; -- from cs2000
		fref : in std_logic; -- from the oscillator
		fout : out std_logic -- to CS2000
	);
end top;

architecture rtl of top is
	
	-- Reset pulse
	component rstpulse is
		generic (N : integer := 100000000);
		port (
			cin : in std_logic;
			r : in std_logic := '0';
			rout : out std_logic
		);
	end component rstpulse;
	-- PLL
	component netpll is
		port (
			refclk   : in  std_logic := 'X'; -- clk
			rst      : in  std_logic := 'X'; -- reset
			outclk_0 : out std_logic;        -- clk
			locked   : out std_logic         -- export
		);
	end component netpll;
	
	-- MAC/PHY component
	component tsewrap is
	port (
		clk : in std_logic;
		rst : in std_logic;

		rgmii_rxclk : in std_logic;
		rgmii_rxd : in std_logic_vector(3 downto 0);
		rgmii_rxc : in std_logic;

		rgmii_txclk : out std_logic;
		rgmii_txd : out std_logic_vector(3 downto 0);
		rgmii_txc : out std_logic;

		rx_valid : out std_logic;
		rx_data : out std_logic_vector(31 downto 0);
		rx_empty : out std_logic_vector(1 downto 0);
		rx_sop : out std_logic;
		rx_eop : out std_logic;
		rx_ready : in std_logic;

		tx_valid : in std_logic;
		tx_data : in std_logic_vector(31 downto 0);
		tx_empty : in std_logic_vector(1 downto 0);
		tx_sop : in std_logic;
		tx_eop : in std_logic;
		tx_ready : out std_logic
	);
	end component tsewrap;
	
	-- Clock
	component aclkdiv is
	port (
		clk : in std_logic;
		div2 : out std_logic;
		div4 : out std_logic;
		div8 : out std_logic;
		div256 : out std_logic;
		div512 : out std_logic);
	end component aclkdiv;
	
	-- CRF Frame generator
	component crfframegen is
	port (
		clk           : in std_logic;
		txready       : in std_logic;
		reset         : in std_logic;
		dataout       : out std_logic_vector(31 downto 0);
		packet_start  : out std_logic; 
		packet_end    : out std_logic;
		gptp_request  : out std_logic;
		gptp_data_in  : in std_logic_vector (63 downto 0);
		fifo_empty    : in std_logic;
		datavalid     : out std_logic
	);
	end component crfframegen;
	
	--CRF Frame receiver
	component ethrxmux is
	port (
		clk : in std_logic;
		reset: in std_logic;
		rxready : out std_logic;
		datain : in std_logic_vector(31 downto 0);
		packet_start : in std_logic; 
		packet_end : in std_logic;
		empty: in std_logic_vector(1 downto 0);
		valid: in std_logic;
		avtp_pkt: out std_logic
	);
	end component ethrxmux;
	
	component AVTPDUProcessor is
	port (
		clk : in std_logic;
		reset : in std_logic;
		datain : in std_logic_vector (31 downto 0);
		processing: in std_logic;
		timestamp_valid : out std_logic;
		timestamp_out : out std_logic_vector(63 downto 0);
		first_ts_received : out std_logic;
		buffer_full : in std_logic
	);
	end component AVTPDUProcessor;
	
	-- Mock gPTP generator
	component gptpgen is
		port (
			cin 		     : in std_logic;
			mclk_in 	     : in std_logic;
			reset         : in std_logic;
			fifo_full     : in std_logic;
			fifo_write    : out std_logic;
			timestamp_out : out std_logic_vector(63 downto 0)
		);
	end component gptpgen;
	
	-- CS2000 signal generator
	component csgen is
		port (
			-- clocks
			cin : in std_logic;
			--Ethernet data/timestamps
			rx_timestamp : in std_logic_vector(63 downto 0);
			rx_fifo_rdreq : out std_logic := '0';
			rx_fifo_rdempty : in std_logic;
			-- genclk fifo
			gen_timestamp: in std_logic_vector(63 downto 0);
			gen_fifo_rdreq : out std_logic := '0';
			gen_fifo_rdempty : in std_logic;
			--output waveform to CS2000
			f_out : out std_logic
		);
	end component csgen;
	
	component gen_fifo_driver is
	port (
			gen_clk_in : in std_logic;
			gen_fifo_wrfull : in std_logic;
			rx_ready : in std_logic;
			fifo_wr_req: out std_logic
	);
	end component gen_fifo_driver;
	
	
	--FIFO Buffer for gPTP timestamps
	component FIFO IS
		PORT (
			aclr		: IN STD_LOGIC  := '0';
			data		: IN STD_LOGIC_VECTOR (63 DOWNTO 0);
			rdclk		: IN STD_LOGIC ;
			rdreq		: IN STD_LOGIC ;
			wrclk		: IN STD_LOGIC ;
			wrreq		: IN STD_LOGIC ;
			q			: OUT STD_LOGIC_VECTOR (63 DOWNTO 0);
			rdempty	: OUT STD_LOGIC ;
			wrfull	: OUT STD_LOGIC 
		);
	end component FIFO;
	
	component big_fifo IS
	PORT
	(
		aclr		: IN STD_LOGIC  := '0';
		data		: IN STD_LOGIC_VECTOR (63 DOWNTO 0);
		rdclk		: IN STD_LOGIC ;
		rdreq		: IN STD_LOGIC ;
		wrclk		: IN STD_LOGIC ;
		wrreq		: IN STD_LOGIC ;
		q		: OUT STD_LOGIC_VECTOR (63 DOWNTO 0);
		rdempty		: OUT STD_LOGIC ;
		wrfull		: OUT STD_LOGIC 
	);
	END component big_fifo;

	
	
	-- Define useful signals
	signal pllrst, clknet, pll_locked : std_logic;
	signal rstnet : std_logic;
	signal phyrst_trig, phy_rst, nphy_rst : std_logic;

	signal eth0_rx_valid, eth0_rx_sop, eth0_rx_eop, eth0_rx_ready : std_logic;
	signal eth0_rx_data : std_logic_vector(31 downto 0);
	signal eth0_rx_empty : std_logic_vector(1 downto 0);
	signal eth0_tx_valid, eth0_tx_sop, eth0_tx_eop, eth0_tx_ready : std_logic;
	signal eth0_tx_data : std_logic_vector(31 downto 0);
	signal eth0_tx_empty : std_logic_vector(1 downto 0);
	
	-- ETH Signals for RX (g1)
	signal eth1_rx_valid, eth1_rx_sop, eth1_rx_eop, eth1_rx_ready : std_logic;
	signal eth1_rx_data : std_logic_vector(31 downto 0);
	signal eth1_rx_empty : std_logic_vector(1 downto 0);
	signal eth1_tx_valid, eth1_tx_sop, eth1_tx_eop, eth1_tx_ready : std_logic;
	signal eth1_tx_data : std_logic_vector(31 downto 0);
	signal eth1_tx_empty : std_logic_vector(1 downto 0);

	signal gen_fref : std_logic := '0';
	
	-- Signals Mock GPTP
	signal gptp_timestamp : std_logic_vector(63 downto 0);
	
	-- Signals GPTP TX FIFO
	signal tx_fifo_q : std_logic_vector(63 downto 0);
	signal tx_fifo_full : std_logic;
	signal tx_fifo_write : std_logic;
	signal tx_fifo_empty : std_logic;

	
	signal pktgen_tx_fifo_read : std_logic;

	-- FOR THE RX FIFO
	signal rx_fifo_q : std_logic_vector(63 downto 0);
	signal rx_fifo_full : std_logic;
	signal rx_fifo_write : std_logic;
	signal rx_fifo_empty : std_logic;
	signal rx_fifo_rdusedw : std_logic_vector(5 downto 0);
	signal rx_fifo_wrusedw : std_logic_vector(5 downto 0);
	
	-- FOR THE genclk fifo
	signal gen_fifo_q : std_logic_vector(63 downto 0);
	signal gen_fifo_rdreq : std_logic;
	signal gen_fifo_full : std_logic;
	signal gen_fifo_write : std_logic;
	signal gen_fifo_empty : std_logic;
	
	-- driver signal so we can slow down write requests
	signal gen_fifo_driver_wrreq : std_logic := '0';
	
	-- From ETH mux
	signal eth_rx_processing_avtpdu : std_logic;
	
	signal rx_timestamp_data : std_logic_vector(63 downto 0);
	signal rx_timestamp_valid : std_logic;
	
	-- from AVTPDUProcessor to cs2000
	signal rx_fifo_timestamp_q : std_logic_vector(63 downto 0);
	signal cs_timestamp_request : std_logic;
	
	-- OTHER
	signal ref_fs_int : std_logic;
	
	signal rsvd2_debounced : std_logic;
	
	signal fout_int : std_LOGIC;
	signal rx_fs_int : std_LOGIC;
	
--	signal twice_rx_fs_int : std_logic;
	
	
	signal AVTPDU_received : std_logic := '0';

begin
	gb_mdc <= '0';
	gb_mdio <= 'Z';
	
	-- LEDs
	statusled <= rsvd2;
	fpgaled <= '1';
	
	-- Create the basic clock we're using
	-- clknet is a 125MHz clock.
	net_inst : netpll port map (
		refclk => osc25,
		rst => pllrst,
		locked => pll_locked,
		outclk_0 => clknet
	);
	
	pllrst_inst : rstpulse
		generic map (N => 250000) --10ms
		port map (
			cin => osc25,
			rout => pllrst
		);
	pkgenrst_inst : rstpulse
		generic map (N => 25000000) --200ms
		port map (
			r => phyrst_trig,
			cin => clknet,
			rout => rstnet
		);
	phyrst_trig <= pllrst or not pll_locked or not rsvd1;
	phyrst_inst : rstpulse
		generic map (N => 12500000) --100ms
		port map (
			cin => clknet,
			r => phyrst_trig,
			rout => phy_rst
		);
	gb_nrst(0) <= not phy_rst;
	gb_nrst(1) <= not phy_rst;

	
	-- instantiate CRF Frame generator
	pktgen: crfframegen port map (
		clk => clknet,
		txready => eth0_tx_ready,
		reset => not rstnet,
		dataout => eth0_tx_data,
		packet_start => eth0_tx_sop,
		packet_end => eth0_tx_eop,
		gptp_request => pktgen_tx_fifo_read,
		gptp_data_in => tx_fifo_q,
		fifo_empty => tx_fifo_empty,
		datavalid => eth0_tx_valid
	);
	
	--instantiate CRF Frame receiver
	pktrec: ethrxmux port map (
		clk => clknet,
		reset => not rstnet,
		rxready => eth1_rx_ready,
		valid => eth1_rx_valid,
		empty => eth1_rx_empty,
		datain => eth1_rx_data,
		packet_start => eth1_rx_sop,
		packet_end => eth1_rx_eop,
		avtp_pkt => eth_rx_processing_avtpdu
	);
	
	-- Instantiate mock gptp
	gptp_inst: gptpgen port map (
		cin           => clknet,
		mclk_in       => ref_fs_int,
		reset         => not rstnet,
		fifo_full     => tx_fifo_full,
		fifo_write    => tx_fifo_write,
		timestamp_out => gptp_timestamp
	);
	
	-- FIFO for TX gPTP timestamps
	TX_fifo : FIFO PORT MAP (
		aclr 		=> rstnet,
		data		=> gptp_timestamp,
		rdclk		=> clknet, -- 125Mhz
		rdreq 	=> pktgen_tx_fifo_read,
		wrclk 	=> ref_fs_int,
		wrreq 	=> tx_fifo_write,
		q     	=> tx_fifo_q,
		rdempty 	=> tx_fifo_empty,
		wrfull  	=> tx_fifo_full
	);
	
	-- FIFO for RX. handles all incoming data
	RX_fifo : FIFO PORT MAP (
		aclr 		=> rstnet,
		data		=> rx_timestamp_data, -- from crf listener
		rdclk		=> osc25, -- To match with CS2000 generator
		rdreq 	=> cs_timestamp_request,
		wrclk		=> clknet,
		wrreq 	=> rx_timestamp_valid, -- from crf listener
		q     	=> rx_fifo_timestamp_q, -- in to CS2000 gen
		rdempty 	=> rx_fifo_empty,
		wrfull  	=> rx_fifo_full
	);
	
	
	
	-- FIFO for generated timestamps
	gen_fifo : big_fifo PORT MAP (
		aclr 		=> rstnet,
		data		=> gptp_timestamp, 
		rdclk		=> osc25, 
		rdreq 	=> gen_fifo_rdreq,
		wrclk		=> rx_fs_int,
		wrreq 	=> (not gen_fifo_full) AND rx_fs_int AND eth1_rx_ready,
		q     	=> gen_fifo_q, -- in to CS2000 gen
		rdempty 	=> gen_fifo_empty,
		wrfull  	=> gen_fifo_full
	);
	
	-- Instantiate a listener
	crf_processor : AVTPDUProcessor port map (
		clk => clknet,
		reset => not rstnet,
		datain => eth1_rx_data,
		processing => eth_rx_processing_avtpdu,
		timestamp_valid => rx_timestamp_valid,
		timestamp_out => rx_timestamp_data,
		first_ts_received => AVTPDU_received,
		buffer_full => rx_fifo_full
	);
	
	-- CRF Talker ETH (TX)
	g0 : tsewrap port map (
		clk => clknet,
		rst => rstnet,
		rgmii_rxclk => g0_rx_clk,
		rgmii_rxd => g0_rx_d,
		rgmii_rxc => g0_rx_dv,
		rgmii_txclk => g0_tx_clk,
		rgmii_txd => g0_tx_d,
		rgmii_txc => g0_tx_en,
		rx_valid => eth0_rx_valid,
		rx_data => eth0_rx_data,
		rx_empty => eth0_rx_empty,
		rx_sop => eth0_rx_sop,
		rx_eop => eth0_rx_eop,
		rx_ready => eth0_rx_ready,
		tx_valid => eth0_tx_valid,
		tx_data => eth0_tx_data,
		tx_empty => eth0_tx_empty,
		tx_sop => eth0_tx_sop,
		tx_eop => eth0_tx_eop,
		tx_ready => eth0_tx_ready
	);
	-- CRF Listener ETH (RX)
	g1 : tsewrap port map (
		clk => clknet,
		rst => rstnet,
		rgmii_rxclk => g1_rx_clk,
		rgmii_rxd => g1_rx_d,
		rgmii_rxc => g1_rx_dv,
		rgmii_txclk => g1_tx_clk,
		rgmii_txd => g1_tx_d,
		rgmii_txc => g1_tx_en,
		rx_valid => eth1_rx_valid,
		rx_data => eth1_rx_data,
		rx_empty => eth1_rx_empty,
		rx_sop => eth1_rx_sop,
		rx_eop => eth1_rx_eop,
		rx_ready => eth1_rx_ready,
		tx_valid => eth1_tx_valid,
		tx_data => eth1_tx_data,
		tx_empty => eth1_tx_empty,
		tx_sop => eth1_tx_sop,
		tx_eop => eth1_tx_eop,
		tx_ready => eth1_tx_ready
	);
	
	--generator signals 
	-- TODO
	eth0_tx_empty <= (others => '0');
	
	cs2000_inst: csgen port map (
		--clocks
		cin => osc25, -- should be asynchrnonous to audio reference clocks
		
		--Ethernet data/timestamps
		rx_timestamp => rx_fifo_timestamp_q,
		rx_fifo_rdreq => cs_timestamp_request,
		rx_fifo_rdempty => rx_fifo_empty,
		
		-- gen Fifo signals
		gen_timestamp => gen_fifo_q,
		gen_fifo_rdreq => gen_fifo_rdreq,
		gen_fifo_rdempty => gen_fifo_empty,
	
		-- the output waveform
		f_out => fout_int
	);
	
	-- 24.576MHz reference/source
	refdiv : aclkdiv port map (
		clk => fref,
		div2 => ref_mck,
		div8 => ref_bck,
		div512 => ref_fs_int); -- 48kHz
		
	ref_fs <= ref_fs_int;
	
	-- Listener
	-- This is the CS2k output
	rxdiv : aclkdiv port map (
		clk => fin, -- fin for CS2000 output
		div2 => rx_mck,
		div8 => rx_bck,
--		div256 => twice_rx_fs_int,
		div512 => rx_fs_int);
	rx_fs <= rx_fs_int;
	
	fout <= fout_int;
end architecture;
