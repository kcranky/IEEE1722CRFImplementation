-- Filename: 
--   csgen.vhd

-- Description:
--   Compares talker and listener timestamps
--   Determines a phase difference between the two
--   Controls the phase of the listener media clock by controlling a CS2000 IC

-- Author:
--  Keegan Crankshaw

-- Date: 
--   December 2020

-- Available on GitHub: 
--   https://github.com/kcranky/IEEE1722CRFImplementation

-- Licence: 
--   MIT
--   https://github.com/kcranky/IEEE1722CRFImplementation/blob/main/LICENSE

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

entity csgen is
	port (
		-- two input clocks
		cin : in std_logic; -- currently 25Mhz
		--Ethernet data/timestamps
		rx_timestamp : in std_logic_vector(63 downto 0);
		rx_fifo_rdreq : out std_logic;
		rx_fifo_rdempty : in std_logic;
		-- generated timestamps
		gen_timestamp: in std_logic_vector(63 downto 0);
		gen_fifo_rdreq : buffer std_logic := '0';
		gen_fifo_rdempty : in std_logic;
        
		f_out : out std_logic
	);
end csgen;
  
architecture rtl of csgen is
	-- There's an interesting relationship betweem lgcoeff, and phase_step.
	-- Larger lgcoeff means smaller corrections to errors, which is good, but can result in slow settling time.
	-- Compromise is to adjust the phase_step. SO the maths doesn't work out exactly as calculated (originally relating phase_step to the ns time by 2^-8),
	-- but it means a better relation of the correction value to 0 degrees phase
	constant lgcoeff : integer := 0;
	constant num_bits : integer :=  26; -- number of bits required to represent count_to. Done for easier testing, is all
	constant phase_step : integer := 2800; 
	constant count_to : unsigned(num_bits downto 0) := to_unsigned(phase_step*12500, num_bits+1);-- 12500*phase_step for 25MHz to product 1 kHz
		
	-- A just checks if the talker and listener timestamp are within range.
	-- Because listeners are stored each mclk event, and talkers every 160th, we need to ensure the listener timestamp relates to the current talker timestamp
	-- We choose half the period because the listener can lead or lag the talker by up to 180 degrees
	-- We add 1 phase step because we want to give preference to pushing the generated waveform back instead of correcting in the same direction as the drift
	constant A : unsigned(63 downto 0) := to_unsigned(10416, 64); -- 10416 + degree offset 
	
	-- FSM for the module
	TYPE State_type IS (ST_INIT, ST_FETCH, ST_CALCULATE, ST_WAIT);  
	SIGNAL state : State_Type := ST_INIT;
		
		
begin
   -- set the output/control wave to the CS2000
	generate_clock : process(cin)
		-- Variables are used because we need them within the same state of the FSM
		-- the internal count value, when reaching count_to, toggles f_out_int which drives the CS2000
		variable cnt_int : unsigned(num_bits downto 0); 
		variable f_out_int : std_logic := '1';
		-- waves state and prev state are used to detect changes in the correction algorithm and determine when we need to fetch new timestamps
		variable waves_state: std_logic_vector(1 downto 0);
		variable prev_state: std_logic_vector(1 downto 0);
		variable difference : unsigned(63 downto 0);	
		
		-- gen_lagging tells us if the listener is ahead or behind the talker timestamp. 
		-- Error tells us if we're working with related timestamps
		-- correction is a calculated
		variable gen_lagging : std_logic := '0';
		variable error : std_logic := '0';
		variable correction : unsigned(63 downto 0);
		
		-- As above but for a rolling average low pass filter
		variable filter_lagging : std_logic := '0';
		variable filter_correction : unsigned(63 downto 0);
		
		
		variable runing_total : unsigned(63 downto 0);
		variable previous_timestamp : unsigned(63 downto 0);
		
	begin
		if rising_edge(cin) then
		
			if (error = '1') then
				if (filter_lagging = '1') then -- gen has come sooner, meaning that we need to make it arrive later next time
					if cnt_int > filter_correction(num_bits downto 0) then
						cnt_int := cnt_int + phase_step - filter_correction(num_bits downto 0) ;
					else
						cnt_int := to_unsigned(0, num_bits+1);
					end if;
				else
					if cnt_int + filter_correction(num_bits downto 0) < count_to then
						cnt_int := cnt_int + phase_step + filter_correction(num_bits downto 0) ;
					else
						cnt_int := cnt_int + phase_step;
					end if;
				end if;
				error := '0'; -- "ack" the error
			else 
				cnt_int := cnt_int + phase_step;
			end if;
					
		-- TODO: handle phase drift here
			
			
			-- check if we need to toggle 
			if cnt_int >= count_to then 
				cnt_int := (others => '0');
				f_out_int := not f_out_int;
			end if;
			
			case state is 
				when ST_INIT =>				
					-- we wait until we've received the first timestamps
					if (gen_fifo_rdempty = '0') and (rx_fifo_rdempty = '0') then
							rx_fifo_rdreq <= '1';
							gen_fifo_rdreq <= '1';
							state <= ST_WAIT;
					end if;
			
				

				-- we have timestamps, now let's work with them
				when ST_CALCULATE =>
					rx_fifo_rdreq <= '0';
					gen_fifo_rdreq <= '0';
					
					-- Determine if there is actually a correction to be made
					if unsigned(rx_timestamp) < unsigned(gen_timestamp)then
						gen_lagging := '0';
						difference := unsigned(gen_timestamp) - unsigned(rx_timestamp);
						if difference <= (A) then
							error := '1';
							correction := shift_right(difference, lgcoeff);
						else
							error := '0';
							correction := (others => '0');
						end if;
					else --if unsigned(rx_timestamp) >= unsigned(gen_timestamp) then
						gen_lagging := '1';
						difference := unsigned(rx_timestamp) - unsigned(gen_timestamp);
						if difference <= (to_unsigned(20834,64) - A) then
							error := '1';
							correction := shift_right(difference, lgcoeff);
							
						else
							error := '0';
							correction := (others => '0');
						end if;
					end if;
					
					-- Filter the signal
					if error = '1' then
						if filter_lagging = gen_lagging then
							filter_correction := shift_right(correction + filter_correction,1);
						else
							if correction >= filter_correction then
								filter_lagging := not filter_lagging;
							end if;
							filter_correction := shift_right(unsigned(abs(signed(filter_correction) - signed(correction))),1);
						end if;
					end if;
					
					state <= ST_FETCH;
					
				
				when ST_FETCH =>
					waves_state := (gen_lagging & error);
					case (waves_state) is
					-- found an error
						when "01" | "11" =>
							-- fetch both
							if rx_fifo_rdempty = '0' and  gen_fifo_rdempty = '0' then
								rx_fifo_rdreq <= '1';
								gen_fifo_rdreq <= '1';
								state <= ST_WAIT;
							end if;
							
						when "00" =>
							-- gen is behind RX (gen lead is false)
							-- no error detected
						
							-- gen_lagging after RX, no error detected
							-- fetch rx
							-- gen leading should continue to fetch gen TS until gen = RX + 159*20832???
							if rx_fifo_rdempty = '0' then
								rx_fifo_rdreq <= '1';
								state <= ST_WAIT;
							end if;
							
						when "10" =>
							-- gen < rx, fetch gen
							if gen_fifo_rdempty = '0' then
								gen_fifo_rdreq <= '1';
								state <= ST_WAIT;
							end if;
					end case;
					
				when ST_WAIT =>
					rx_fifo_rdreq <= '0';
					gen_fifo_rdreq <= '0';
					state <= ST_CALCULATE;
					
			end case;
			
		end if; -- end rising edge

	f_out <= f_out_int; -- tie the input variable to the signal out
		
	end process;
	
end;
