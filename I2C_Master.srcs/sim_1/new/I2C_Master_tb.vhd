----------------------------------------------------------------------------------
-- Company: 
-- Engineer: 
-- 
-- Create Date: 2023/02/14 18:59:59
-- Design Name: 
-- Module Name: IIC_Master_tb - Behavioral
-- Project Name: 
-- Target Devices: 
-- Tool Versions: 
-- Description: 
-- 
-- Dependencies: 
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
-- 
----------------------------------------------------------------------------------


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx leaf cells in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

entity I2C_Master_tb is
--  Port ( );
end I2C_Master_tb;

architecture Behavioral of I2C_Master_tb is
component I2C_Master is
    Generic (
        SYS_CLK_VAL_HZ      :   integer := 50_000_000;  -- 50MHz  系统输入时钟值 单位：Hz
        SCL_VAL_HZ          :   integer := 400_000;     -- 400KHz SCL
        I2C_SLAVE_ADDR_LEN  :   integer :=  7           -- I2C从机地址位数 7 / 10bit
    );
    Port (
        i_SysClk    :   in      std_logic;  -- 系统时钟
        i_SysNrst   :   in      std_logic;  -- 系统异步复位
        i_EN        :   in      std_logic;  -- 系统控制模块工作使能位 模块使能：1，禁用：0
        
        i_SlaveAddr :   in      std_logic_vector(I2C_SLAVE_ADDR_LEN-1 downto 0);    -- I2C从机地址
        i_WDataByte :   in      std_logic_vector(7 downto 0);
        i_RW        :   in      std_logic;  -- I2C读写操作指示位 Read：1，Write：0
        i_RWTrigger :   in      std_logic;  -- 
        
        o_RDataByte :   out     std_logic_vector(7 downto 0);
        o_IdleFlag  :   out     std_logic;  -- I2C处于空闲标志位 空闲：1，忙：0
        o_RWOkPulse :   out     std_logic;  -- I2C读写操作完成脉冲标志信号 一个高脉冲
        o_ErrorFlag :   out     std_logic;  -- 错误标志位 错误：1，无错：0
        
        io_SDA      :   inout   std_logic;  -- SDA数据引脚 双向
        io_SCL      :   inout   std_logic   -- SCL时钟引脚 双向
    );
end component;

signal clk: std_logic;
signal nrst:std_logic;
signal sda: std_logic;
signal scl: std_logic;
signal readData: std_logic_vector(7 downto 0);
signal idleFlag: std_logic;
signal RWWellPulse: std_logic;
signal errorFlag: std_logic;
signal s_RWEN: std_logic    :=  '0';
signal s_addr:std_logic_vector(6 downto 0) := "1001011";
signal s_RW : std_logic :=  '0';

signal cnt :integer := 0;
begin
clk_proc: process
begin
    clk <= '1';
    wait for 10ns;
    clk <= '0';
    wait for 10ns;
end process;

nrst_proc: process
begin
    nrst <= '0';
    wait for 73ns;
    nrst <= '1';
    wait;
end process;

RWEN_proc: process(clk, nrst)
begin
    if (nrst = '0') then
        cnt <= 0;
        s_RWEN <= '0';
    elsif (rising_edge(clk)) then
--        if (cnt = 20) then
--            cnt <= cnt;
--        else
--            cnt <= cnt + 1;
--        end if;
--        if (cnt = 0) then
--            s_Rwen <= '0';
--        elsif (cnt = 2) then
--            s_Rwen <= '1';
--        else
--            s_RWEN <= '0';
--        end if;
        if (idleFlag = '1' and Cnt = 0) then
            s_RWEN <= '1';
            Cnt <= Cnt + 1;
            s_RW <= '0';
        elsif (RWWellPulse = '1' and Cnt = 1) then
            s_RWEN <= '1';
            Cnt <= Cnt + 1;
            --s_addr <= "1001111";
            s_RW <= '1';
        elsif (RWWellPulse = '1' and Cnt = 3) then
            s_RWEN <= '1';
            Cnt <= Cnt + 1;
            --s_addr <= "1001111";
            s_RW <= '0';
        else
            s_RWEN <= '0';
        end if;
    end if;

end process;

iic: I2C_Master
    Generic map(
        SYS_CLK_VAL_HZ   => 50_000_000,  -- 50MHz  系统输入时钟值 单位：Hz
        SCL_VAL_HZ       => 400_000,     -- 400KHz SCL
        I2C_SLAVE_ADDR_LEN  => 7           -- I2C从机地址位数 7 / 10bit
    )
    Port map (
        i_SysClk    => clk,  -- 系统时钟
        i_SysNrst   => nrst,  -- 系统异步复位
        i_EN        => '1',  -- 系统控制模块工作使能位 模块使能：1，禁用：0
        
        i_SlaveAddr =>  s_addr,    -- I2C从机地址
        i_WDataByte  => x"AA",
        i_RW        => s_RW,      -- I2C读写操作指示位 Read：1，Write：0
        i_RWTrigger => s_RWEN,      -- I2C读写操作使能位 启用读写：1，禁用读写：0
        
        o_RDataByte =>   readData,
        o_IdleFlag  =>   idleFlag,  -- I2C处于空闲标志位 空闲：1，忙：0
        o_RWOkPulse =>   RWWellPulse,  -- I2C读写操作完成脉冲标志信号 一个高脉冲
        o_ErrorFlag =>   errorFlag,  -- 错误标志位 错误：1，无错：0
        
        io_SDA      =>   sda,  -- SDA数据引脚 双向
        io_SCL      =>   scl   -- SCL时钟引脚 双向
    );

end Behavioral;
