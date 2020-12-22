library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity aclkdiv is
port (
	clk : in std_logic;
	div2 : out std_logic;
	div4 : out std_logic;
	div8 : out std_logic;
	div256 : out std_logic;
	div512 : out std_logic);
end entity aclkdiv;

architecture rtl of aclkdiv is
begin
	process (clk)
		variable cnt : std_logic_vector(8 downto 0) := (others => '0');
	begin
		if rising_edge(clk) then
			cnt := std_logic_vector(unsigned(cnt) + 1);
			div512 <= cnt(8);
			div256 <= cnt(7);
			div8 <= cnt(2);
			div4 <= cnt(1);
			div2 <= cnt(0);
		end if;
	end process;
end architecture;

