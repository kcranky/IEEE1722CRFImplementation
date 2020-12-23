library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;


entity ethrxmux is
	port (
		clk : in std_logic;
		packet_start, packet_end, valid, reset : in std_logic;
		empty : in std_logic_vector (1 downto 0);
		datain : in std_logic_vector (31 downto 0);
		rxready : out std_logic;
		avtp_pkt: out std_logic
	);
end ethrxmux;

architecture rtl of ethrxmux is 
	constant AVTP_TYPE : std_logic_vector(15 downto 0) := x"22F0"; -- ETH TYPE for AVTP Packets
	
	-- FSM
	type State_type is (ST_CONFIG, ST_START, ST_HEADER, ST_RECEIVE);  
	signal state : State_Type := ST_CONFIG; 
	signal rxready_int : std_logic := '1';

begin

	-- The clocked process which acts as a MUX
	output: process (clk, reset) 
	begin
	

	if reset = '0' then
		rxready_int <= '0';
		state <= ST_CONFIG;
		
	elsif rising_edge(clk) then
		case state is 
			when ST_CONFIG =>
				avtp_pkt <= '0';
				rxready_int <= '1';
				state <= ST_START;
				
			when ST_START =>
				-- stay here until sop received
				if packet_start = '1' AND rxready_int = '1' then
					state <= ST_HEADER;
				end if;
			
			-- Wait until we get ETH_TYPE expected, otherwise just move to ST_START
			when ST_HEADER =>
				if rxready_int = '1' then
					-- if we get AVTP
					if datain(15 downto 0) = AVTP_TYPE then -- 15 downto 0 to compensate for leading 2 bytes
						avtp_pkt <= '1';
						state <= ST_RECEIVE;
						
					-- any other ETH Types can be handled here
					
					-- if we didn't receive any expected packets
					elsif packet_end = '1' then
						state <= ST_START;
					end if;
					
				end if;
			
			when ST_RECEIVE =>
				if rxready_int = '1' then
					-- Wait until we get eop
					if packet_end = '1' then
						avtp_pkt <= '0';
						state <= ST_START;
					end if;
				end if;

				
			
		end case;
		
	end if;
	end process;
	
	rxready <= rxready_int;
	
	
end architecture;
