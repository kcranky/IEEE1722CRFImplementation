library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity AVTPDUProcessor is
	-- just define our constants
	generic(
		AVTP_SUBTYPE : std_logic_vector(7 downto 0) := x"04" -- something we're looking for
	);
	port (
		clk : in std_logic;
		reset : in std_logic;
		datain : in std_logic_vector (31 downto 0);
		processing: in std_logic;
		timestamp_valid : out std_logic := '0';
		timestamp_out : out std_logic_vector(63 downto 0);
		first_ts_received : out std_logic := '0';
		
		buffer_full : in std_logic
	);
end AVTPDUProcessor;

architecture rtl of AVTPDUProcessor is 
	
	-- Timestamp array
	type T_timestamp_arr is array (1 to 6) of std_logic_vector(63 downto 0);
	SIGNAL timestamp_array : T_timestamp_arr;
	
	signal ts : std_logic_vector(63 downto 0);
	signal ts_val : std_logic := '0';
	
	-- Data from the CRF Frame
	SIGNAL SUB_TYPE : std_logic_vector (7 downto 0);
	SIGNAL SV : std_logic; -- Stream valid
	SIGNAL MR : std_logic; -- Media Clock Reset
	SIGNAL TU : std_logic; -- timestamp uncertain
	SIGNAL SEQ_NUM: std_logic_vector (7 downto 0) := (others => '0'); -- Increases with each new frame sent
	SIGNAL CRF_TYPE : std_logic_vector (7 downto 0); -- expect AVTP subtype of x04 here
	SIGNAL STREAM_ID : std_logic_vector (127 downto 0);
	SIGNAL PULL : std_logic_vector (2 downto 0);
	SIGNAL BASE_FREQ : std_logic_vector (28 downto 0);
	SIGNAL CRF_DATA_LEN : std_logic_vector (15 downto 0);
	SIGNAL TS_INTERVAL : std_logic_vector (15 downto 0); -- number of clock events between timestamps
	
	-- FSM
	TYPE State_type IS (ST_WAIT, ST_CONFIG, ST_TIMESTAMPS);  
	SIGNAL state : State_Type := ST_WAIT;  -- Create a signal that uses the state
	-- FSM for config data
	TYPE config_states IS (C_ST_STREAMID, C_ST_FREQ, C_ST_CRF_DATA);  
	SIGNAL CONFIG_STATE : config_states := C_ST_STREAMID;  -- Create a signal that uses the state
		
	attribute syn_keep : boolean;
	attribute keep : boolean;
	attribute syn_keep of SV : SIGNAL is true;
	attribute syn_keep of MR : SIGNAL is true;
	attribute syn_keep of TU : SIGNAL is true;
	attribute syn_keep of SEQ_NUM : SIGNAL is true;
	attribute syn_keep of PULL : SIGNAL is true;
	attribute syn_keep of BASE_FREQ : SIGNAL is true;
	attribute syn_keep of CRF_DATA_LEN : SIGNAL is true;
	attribute syn_keep of TS_INTERVAL : SIGNAL is true;
	attribute syn_keep of timestamp_array : SIGNAL is true;
	
begin
	
	output: process (clk, reset) 
		variable s_id_count : integer range 0 to 1 := 0; -- Stream ID count
		variable ts_count : integer range 1 to 7 := 1; -- 1722 specifies a max possible 6 timestamps per AVTPDU
		-- keep track of upper/lower 32 bits
		variable timestamp_msb : boolean := true;
		
	begin
	
	-- reset triggered
	if reset = '0' then
		state <= ST_WAIT;
		
	elsif rising_edge(clk) then
		
		-- if at any point the processing flag goes low, we need to treat that as a reset
		if processing = '0' then
				state <= ST_WAIT;
		end if;
	
		case state is 
			when ST_WAIT =>
				timestamp_valid <= '0';
				if processing = '1' then -- we need a way to ensure we get the FIRST set of 32 bits here, otherwise we end up with garbage.
					first_ts_received <= '1'; -- set the first time we get a timestamp, sent to genFIFO to start generating timestamps there.
					-- we get the first 32 bits here
					if datain(31 downto 24) = AVTP_SUBTYPE then -- the trigger for the config process
						SV <= datain(23);
						-- Version <= datain(22 downto 20)
						MR <= datain(19);
						-- R <= datain(18)
						-- FS <= datain(17)
						TU <= datain(16);
						SEQ_NUM <= datain(15 downto 8);
						CRF_TYPE <= datain(7 downto 0);
						s_id_count := 0;
						state <= ST_CONFIG;
					end if;
					
				end if;
				
			when ST_CONFIG =>
				case CONFIG_STATE is
				   -- the next 2 * 32 bits are stream_id
					when C_ST_STREAMID =>
						if s_id_count = 0 then
							STREAM_ID(127 downto 96) <= datain;
						elsif s_id_count = 1 then
							STREAM_ID(31 downto 0) <= datain;
							CONFIG_STATE <= C_ST_FREQ;
						end if;
												
						s_id_count := s_id_count +1;
						
					-- the next 32 bits are pull(3) and base freq(29)
					when C_ST_FREQ =>
						PULL <= datain(31 downto 29);
						BASE_FREQ <= datain(28 downto 0);
						CONFIG_STATE <= C_ST_CRF_DATA;
					
					
					-- the next 32 bits are crf_DATA_LEN (16) and ts_INTERVAL(16)
					when C_ST_CRF_DATA =>
						CRF_DATA_LEN <= std_logic_vector(unsigned(datain(31 downto 16))/8);
						TS_INTERVAL <= datain(15 downto 0);
						CONFIG_STATE <= C_ST_STREAMID;
						state <= ST_TIMESTAMPS;
						ts_count := 1;
						timestamp_msb := true; -- FORCED MSB HIGH HERE
				end case;
			
			-- DEBUG ISSUE HERE
			when ST_TIMESTAMPS =>
				if ts_val = '1' then
					-- write to the fifo
					timestamp_valid <= '1';
				end if;
				
				if timestamp_msb = true then -- we make the assumption we start here
					timestamp_array(ts_count)(63 downto 32) <= datain;
					timestamp_msb := not timestamp_msb;
					timestamp_valid <= '0';
					timestamp_out(63 downto 32) <= datain;
					ts_val <= '0';
				else -- timestamp msb is false (0)
					timestamp_array(ts_count)(31 downto 0) <= datain;
					timestamp_msb := not timestamp_msb;
					ts_count  := ts_count + 1;
					timestamp_out(31 downto 0) <= datain;
					ts_val <= '1';
						if buffer_full = '0' then -- Added this check to prevent writing if full and potentially corrupting data
							timestamp_valid <= '1';
						end if;
					
				end if;
				
				if (ts_count = to_integer(unsigned(CRF_DATA_LEN)) +1) and (timestamp_msb = false) then
						state <= ST_WAIT;
						timestamp_valid <= '0';
				end if;
				
		end case;
		
	end if;
	
	end process;
	
end architecture;