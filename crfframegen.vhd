library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

--TODO
----See Table 27 for TX and RX latency
-- -- Stream valid
-- -- Timestamp uncertain
-- -- ST_WAIT delay length to ensure 50 packets/S

entity crfframegen is
	-- just define our constants
	generic (		
		MAC_DEST : std_logic_vector(47 downto 0) := x"FFFFFFFFFFFF";
		MAC_SRC : std_logic_vector(47 downto 0) :=  x"987654321036";
		ETH_TYPE : std_logic_vector(15 downto 0) := x"22F0";
		
		CRF_SUBTYPE : std_logic_vector (7 downto 0) := x"04"; -- defined in T. 6 of IEEE1722-2016
		SV : std_logic := '1'; -- stream valid
		VERSION : std_logic_vector := "000"; -- as per definition
		R : std_logic := '0'; -- reserved
		FS : std_logic := '0'; -- as per definition (10.4.13.3)
		
		
		CRF_TYPE: std_logic_vector := x"01"; -- As per T26
		PULL : std_logic_vector := "000"; -- multiplier modifier of base_freq to calculate nominal sampling rate of stream (see T27)
		BASE_FREQ: std_logic_vector (28 downto 0):= "0" & x"000BB80"; -- Nominal sampling rate in Hz - 48000
		CRF_DATA_LENGTH : std_logic_vector := x"0030"; -- 6 CRF stamps = 48 octets = hex30
		TIMESTAMP_INTERVAL : std_logic_vector := x"00A0"; --Table 28 dictates 160 events 
		FRM_LEN: integer := 656 -- The length of the frame in bits
	);
	port (
		clk, txready, reset : in std_logic;
		packet_start, packet_end : out std_logic; -- referred to as SOP and EOP in TSE so left that way
		dataout : out std_logic_vector (31 downto 0);
		gptp_request : out std_logic := '0'; -- Sent to FIFO
		gptp_data_in : in std_logic_vector (63 downto 0);
		fifo_empty : in std_logic;
		datavalid : out std_logic
	);
end crfframegen;

architecture rtl of crfframegen is 
	-- FRAME
	SIGNAL FRAME : std_logic_vector (FRM_LEN-1 downto 0);
	
	-- Signals that change during transmission
	SIGNAL seq_num : std_logic_vector (7 downto 0) := (others => '0'); -- Increases with each new frame sent
	SIGNAL CRF_DATA : std_logic_vector (63 downto 0);
	SIGNAL MR : std_logic := '0';
	SIGNAL TU : std_logic := '0'; -- timestamp uncertain (4.4.4.7)
	
	-- FSM
	TYPE State_type IS (ST_INIT, ST_RESET, ST_START, ST_TRANSMIT, ST_TIMESTAMPS, ST_END, ST_WAIT);  -- Define the states
	SIGNAL state : State_Type := ST_INIT;  -- Create a signal that uses the state
	
	
	type T_timestamp_arr is array (1 to 6) of std_logic_vector(63 downto 0);
	signal timestamp_array : T_timestamp_arr;
	
	signal ts_count : integer range 1 to 6 := 1;
	
	-- Signal tap configuration
	attribute preserve : boolean;
	attribute keep : boolean;
	attribute preserve of timestamp_array: signal is true;
	attribute keep of timestamp_array: signal is true;
	

begin

	
	-- define the frame
	FRAME(FRM_LEN-1  downto FRM_LEN-96) <= MAc_DEST & MAC_SRC;
	FRAME(FRM_LEN-97 downto FRM_LEN-124) <= ETH_TYPE & CRF_SUBTYPE & SV & VERSION;
	FRAME(FRM_LEN-125) <= MR;
	FRAME(FRM_LEN-126 downto FRM_LEN-128) <= R & FS & TU;
	FRAME(FRM_LEN-129 downto FRM_LEN-136) <= seq_num; --sequence number
	FRAME(FRM_LEN-137 downto FRM_LEN-144) <= CRF_TYPE;
	FRAME(FRM_LEN-145 downto FRM_LEN-208) <= MAC_SRC & x"0001"; --Stream_ID Field - 64 bits
	FRAME(FRM_LEN-209 downto FRM_LEN-240)<= PULL & BASE_FREQ; 
	FRAME(FRM_LEN-241 downto FRM_LEN-272) <= CRF_DATA_LENGTH & TIMESTAMP_INTERVAL;
	
	
	output: process (clk, reset) 
		VARIABLE sel_bits : integer range 0 to 21 := 21; -- keep track of which bits to send
		VARIABLE counter : integer range 0 to 2499980 := 0; -- See bottom of file for calculation
		
		-- MR needs to be asserted for at least 8 AVTPDUs before it can change
		VARIABLE MR_Counter : integer range 0 to 8 := 0;
		VARIABLE MR_Flag : std_logic := '0';
		--
		
		variable timestamp_msb : boolean := true;
		
	begin
	if reset='0' then -- if this is low 
		state <= ST_RESET;
	
	elsif rising_edge(clk) then
		
		case state is 
			
			when ST_INIT =>
				if txready = '1' then
					state <= ST_WAIT; 
				end if;
			
			when ST_RESET =>
				counter := 0;
				seq_num <= (others => '0');
				sel_bits := 21;
				timestamp_msb := true;
				ts_count <= 1;
				timestamp_array <= (others => (others => '0'));
				datavalid <= '0';
				if (MR_Flag = '1') then
					MR <= not MR; 
					MR_Flag := '0';
					MR_Counter := 0;
				end if;
				state <= ST_START;
		
			-- Set SOP and send 32 bits
			when ST_START =>
				if (txready = '1') then
						if fifo_empty = '1' then 
							tu <= '1';
						else 
							tu <= '0';
						end if; 
					
					datavalid <= '1';
					packet_start <= '1';
					dataout <= FRAME(sel_bits*32-1 downto  sel_bits*32-32);
					sel_bits := sel_bits-1; 
					state <= ST_TRANSMIT;		
				else
					datavalid <= '0';
				end if;
				
			-- Sends the remaining data up to timestamps
			when ST_TRANSMIT =>
				if (txready = '1') then
					datavalid <= '1';
					packet_start <= '0';
					dataout <= FRAME(sel_bits*32-1 downto sel_bits*32-32);
					sel_bits := sel_bits-1; 
					if (sel_bits = 12) then -- (2*6)
						timestamp_msb := true;
						state <= ST_TIMESTAMPS;
					end if;
				else
					datavalid <= '0';
				end if;
			
			-- This state transmits the timestamps
			when ST_TIMESTAMPS =>
				if timestamp_msb = true then
					dataout <= timestamp_array(ts_count)(63 downto 32);
					timestamp_msb := not timestamp_msb;
				else
					dataout <= timestamp_array(ts_count)(31 downto 0);
					timestamp_msb := not timestamp_msb;
					ts_count <= ts_count +1;
				end if;
				
				if (sel_bits = 2) then
					state <= ST_END;
				end if;
				
				sel_bits := sel_bits-1;
					
			-- Send the last 32 bits, 
			when ST_END => 
					if (fifo_empty = '0') then
						datavalid <= '1';
						dataout <= timestamp_array(ts_count)(31 downto 0);
						sel_bits :=  sel_bits-1; 
						packet_end <= '1';
						gptp_request <= '1';
						ts_count <= 1;
						state <= ST_WAIT;
				else
					datavalid <= '0';
				end if;
				
			
			when ST_WAIT => -- idle until ready
				datavalid <= '0';
				packet_end <= '0';
				counter := counter + 1;
				
				-- Load 6 timestamps into the array
				if ts_count < 7 then
					timestamp_array(ts_count) <= gptp_data_in;
					ts_count <= ts_count +1;
				else 
					gptp_request <= '0';
				end if;
				
				-- End of process
				if (counter = 2499980) then
					sel_bits :=  21;
					ts_count <= 1;
					state <= ST_START;
					counter := 0;
					seq_num <= std_logic_vector(unsigned(seq_num) + 1);
					
					-- Need to ensure that 8 frames are allowed to be sent 
					if (MR_Flag = '0') then
						MR_Counter := MR_Counter + 1;
						if (MR_Counter = 7) then
							MR_Flag := '1';
						end if;
					end if;
					
				end if;
		end case;
	end if;
	end process;

end architecture;


-- Calculating ST_WAIT
-- source osc = 125Mhz
-- Need to send 50 packets/second
-- 125E6/50 = 2.5E6
-- Each packet takes 656/32 = 21 cycles to transmit
-- So delay = 2.5E6 - 21 = 2499979