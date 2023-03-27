----------------------------------------------------------------------------------
-- Company: 
-- Engineer: Ma,Xiufeng
-- 
-- Create Date: 2023/02/13 22:44:41
-- Design Name: 
-- Module Name: I2C_Master - Behavioral
-- Project Name: I2C Master
-- Target Devices: 
-- Tool Versions: Project created with [Vivado 2018.3] use VHDL
-- Description: I2C Msater -  driver
-- 
-- Dependencies: None
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

entity I2C_Master is
    Generic (
        SYS_CLK_VAL_HZ      :   integer := 50_000_000;  -- 50MHz  系统输入时钟值 单位：Hz
        SCL_VAL_HZ          :   integer := 400_000;     -- 400KHz SCL
        I2C_SLAVE_ADDR_LEN  :   integer :=  7           -- I2C从机地址位数 7bit / (10bit不适用)
    );
    Port (
        i_SysClk    :   in      std_logic;  -- 系统时钟
        i_SysNrst   :   in      std_logic;  -- 系统异步复位
        i_EN        :   in      std_logic;  -- 系统控制模块工作使能位 模块使能：1，禁用：0
        
        i_SlaveAddr :   in      std_logic_vector(I2C_SLAVE_ADDR_LEN-1 downto 0);    -- I2C从机地址 7bit
        i_WDataByte :   in      std_logic_vector(7 downto 0);
        i_RW        :   in      std_logic;  -- I2C读写操作指示位 Read：1，Write：0
        i_RWTrigger :   in      std_logic;  -- I2C读写操作使能位 IDLEFlag=1或RWWellPulse=1且下降沿触发写操作，负脉冲
        
        o_RDataByte :   out     std_logic_vector(7 downto 0);
        o_IdleFlag  :   out     std_logic;  -- I2C处于空闲标志位 空闲：1，忙：0
        o_RWOkPulse :   out     std_logic;  -- I2C读写操作完成脉冲标志信号 一个高脉冲
        o_ErrorFlag :   out     std_logic;  -- 错误标志位 错误：1，无错：0
        
        io_SDA      :   inout   std_logic;  -- SDA数据引脚 双向
        io_SCL      :   inout   std_logic   -- SCL时钟引脚 双向
    );
end I2C_Master;

architecture Behavioral of I2C_Master is
-- 常量声明/定义
    constant    c_MACK      :   std_logic   :=  '0';    -- 主机有应答 Master ACK
    constant    c_MNACK     :   std_logic   :=  '1';    -- 主机无应答 Master NACK
    constant    c_SACK      :   std_logic   :=  '0';    -- 从机有应答 Slaver ACK
    constant    c_SNACK     :   std_logic   :=  '1';    -- 从机无应答 Slaver NACK
    constant    c_Cnt       :   integer     :=  (SYS_CLK_VAL_HZ / SCL_VAL_HZ) / 4;    -- 计数比较值 用于生成SclClk 和 SdaClk
-- 寄存器信号声明
    signal      r_Cnt       :   integer     :=   0 ;    -- 计数值 用于生成SclClk 和 SdaClk
    signal      r_SclClk    :   std_logic   :=  '0';
    signal      r_SdaClk    :   std_logic   :=  '0';
    signal      r_SdaClkSync:   std_logic   :=  '0';    -- r_SdaClkSync的延迟一拍
    signal      r_SdaClkFallEdge:std_logic  :=  '0';    -- 此时对应着r_SclClk的高电平约中间位置处
    signal      r_SdaClkRiseEdge:std_logic  :=  '0';    -- 此时对应着r_SclClk的低电平约中间位置处
    
    signal      r_RWTriggerSync  :   std_logic   :=  '0';    -- i_RWTrigger的延迟1拍
    signal      r_StartPulse:   std_logic   :=  '0';    -- 启动指示脉冲
    
    signal      r_IdleFlag  :   std_logic   :=  '1';
    signal      r_AddrCmd   :   std_logic_vector(7 downto 0) := "00000000"; -- 和并地址和RW位
    signal      r_WriteData :   std_logic_vector(7 downto 0) := "00000000"; -- 存放待发送的字节数据
    signal      r_ReadData  :   std_logic_vector(7 downto 0) := "00000000"; -- 存放接收道德字节数据
    
    signal      r_o_SDA     :   std_logic   :=  '1';
    signal      r_i_SDA     :   std_logic;
    signal      r_o_SCL     :   std_logic   :=  '1';
    signal      r_i_SCL     :   std_logic;
    
    type        t_i2cFsm    is (s_Idle, s_Start, s_Stop, s_Command, s_SACK_1, s_SACK_2, s_Write, s_Read, s_MACK, s_WritePending);
    signal      s_i2cFsm    :   t_i2cFsm    :=  s_Idle;
    
    signal      r_GeneralCnt:   integer range 0 to 1000 := 0; -- bit计数 和 边沿等待计数

begin
-- 组合逻辑
    -- 三态门 SDA 和 SCL 端口
    io_SDA  <= '0' when (r_o_SDA = '0') else 'Z';
    r_i_SDA <= io_SDA;
    io_SCL  <= '0' when (r_o_SCL = '0'  and r_SclClk = '0') else 'Z';
    r_i_SCL <= io_SCL;
    
    -- 生成SDA CLK的上升沿，在生成的SCL时钟为低时
    r_SdaClkFallEdge <= '1' when (r_SdaClkSync='1' and r_SdaClk='0') else '0';
    r_SdaClkRiseEdge <= '1' when (r_SdaClkSync='0' and r_SdaClk='1') else '0';
    -- 生成i_RWEN信号的下降沿脉冲信号
    r_StartPulse <= '1' when (r_RWTriggerSync = '0' and i_RWTrigger = '1' and r_IdleFlag = '1') else '0';
    --                      ________________|~~\_______________________
    --                      _________________|~~\______________________
    o_IdleFlag <= r_IdleFlag;
    
    o_RDataByte<= r_ReadData;
-- 时序逻辑
sclSdaClk_proc: process(i_SysClk, i_SysNrst, i_EN)
begin
    if (i_SysNrst = '0' OR i_EN = '0') then
        r_Cnt        <=   0 ;
        r_SclClk     <=  '0';
        r_SdaClk     <=  '0';
        r_SdaClkSync <=  '0';
        r_RWTriggerSync <= '0';
    elsif (rising_edge(i_SysClk)) then
        r_RWTriggerSync <= i_RWTrigger;   -- 对i_RWEN打一拍，用于确定i_RWEN的高脉冲，作为还是否进行数据读写操作的标志信号
        
        r_SdaClkSync <= r_SdaClk;    -- 将r_SdaClk延迟一拍 用于和r_SdaClkSync确定SDA数据变化的位置，即SCL的高低中间位置。
        if (r_Cnt = (c_Cnt*4)-1) then
            r_Cnt <= 0;
        else
            r_Cnt <= r_Cnt + 1;
        end if;
        -- 生成SCL_CLK和SDA_CLK时钟参考信号
        if (r_Cnt >= 0 and r_Cnt < c_Cnt) then
                r_SclClk <= '0';
                r_SdaClk <= '0';
        elsif (r_cnt >= c_Cnt and r_cnt < c_Cnt*2) then
                r_SclClk <= '0';
                r_SdaClk <= '1';
        elsif (r_Cnt >= c_Cnt*2 and r_Cnt < c_Cnt*3) then
                r_SclClk <= '1';
                r_SdaClk <= '1';
        else
                r_SclClk <= '1';
                r_SdaClk <= '0';
        end if;
        
    end if;
end process sclSdaClk_proc;
-- 状态机控制过程
i2c_fsm_proc: process (i_SysClk, i_SysNrst, i_EN)
begin
    if (i_SysNrst = '0' or i_EN = '0') then
        r_GeneralCnt <= 0;
    
        s_i2cFsm <= s_Idle;
        r_IdleFlag <= '1';
        o_RWOkPulse<= '0';
        r_AddrCmd <= "00000000";
        r_WriteData <= "00000000";
        r_o_SCL <= '1';
        r_o_SDA <= '1';
        o_ErrorFlag <= '0';
    elsif(rising_edge(i_SysClk)) then
    
        --if (r_SdaClkRiseEdge = '1') then    -- 系统时钟上升沿 + SDA时钟上升沿，确定SCL低电平中间为开始时刻
        case s_i2cFsm is
            when s_Idle =>  --—————————————- ** 空闲状态
                -- OFL
                r_o_SCL <= '1';
                r_o_SDA <= '1';
                o_ErrorFlag <= '0';
                o_RWOkPulse <= '0';
                r_GeneralCnt <= 0;
                if (r_StartPulse = '1') then
                    r_IdleFlag <= '0';                  -- 开始I2C流程，不在空闲
                    r_AddrCmd <= i_SlaveAddr & i_RW;    -- 将从机地址和读写控制位存储
                    r_WriteData <= i_WDataByte;         -- 将要写的数据字节存储
                    -- i_RWEN <= '1';
                else
                    r_IdleFlag <= '1';
                    r_AddrCmd <= "00000000";
                    r_WriteData <= "00000000";
                end if;
                -- 状态转移和维持
                if (r_StartPulse = '1') then
                    -- NSL
                    s_i2cFsm <= s_Start;
                else
                    -- SM
                    s_i2cFsm <= s_Idle;
                end if;
                
            when s_Start=>  --------------------------- ** I2C启动，SCL高时 SDA从高到低，主机发送
                -- OFL
                -- 等到sda_Clk的上升沿
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_GeneralCnt <= r_GeneralCnt + 1;
                    r_o_SDA <= r_SdaClk;
                    r_o_SCL <= '1';
                -- 有了上升沿，等待下降沿到来
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                    r_o_SCL <= '0';
                    r_o_SDA <= r_SdaClk;
                    r_GeneralCnt <= 7;                  --下个状态发送命令数据，位计数器
                else
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- 状态转移和维持
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                    s_i2cFsm <= s_Command;
                else
                    s_i2cFsm <= s_Start;
                end if;
            when s_Command =>   ------------------------ ** 主机发送从设备地址+RW位
                -- OFL
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt /= 0) then
                    r_o_SDA <= r_AddrCmd(r_GeneralCnt); --bit7-1送到SDA输出
                    r_GeneralCnt <= r_GeneralCnt - 1;
                elsif (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_o_SDA <= r_AddrCmd(r_GeneralCnt); --bit0送到SDA输出
                else
                    r_o_SDA <= r_o_SDA;
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- 状态转移和维持
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    -- NSL
                    s_i2cFsm <= s_SACK_1;
                else
                    -- SM
                    s_i2cFsm <= s_Command;
                end if;
            when s_SACK_1 =>    ------------------------ ** 等待和确认从机发送响应信号
                -- OFL
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then       -- 确定SCL低电平约中间位置
                    r_GeneralCnt <= r_GeneralCnt + 1;
                    r_o_SDA <= '1';  -- 释放SDA线，给从机控制权
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then    --下降沿，SCL为高约中间位置，读SDA的值
                    case r_i_SDA is
                        when c_SACK =>
                            r_GeneralCnt <= 7;
                            o_ErrorFlag <= '0';
                        when others =>
                            r_GeneralCnt <= 0;
                            o_ErrorFlag <= '1';
                    end case;
                else
                    null;
                end if;
                -- 状态转移和维持
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                -- NSL
                    case r_i_SDA is
                        when c_SACK =>
                            if (r_AddrCmd(0) = '0') then -- r_AddrCmd最后一位=0，写数据字节
                                s_i2cFsm <= s_Write;
                            else  -- r_AddrCmd最后一位=1，读数据字节
                                s_i2cFsm <= s_Read;
                            end if;
                        when others =>
                            s_i2cFsm <= s_Stop;
                    end case;
                else
                    -- SM
                    s_i2cFsm <= s_SACK_1;
                end if;
            when s_Write =>  --------------------------- ** 往从机写字节数据
                -- OFL
                r_IdleFlag <= '0';
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt /= 0) then  -- SCL低电平 约中间位置
                    r_o_SDA <= r_WriteData(r_GeneralCnt); --bit7-1送到SDA输出
                    r_GeneralCnt <= r_GeneralCnt - 1;
                elsif (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_o_SDA <= r_WriteData(r_GeneralCnt); --bit0送到SDA输出
                else
                    r_o_SDA <= r_o_SDA;
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- 状态转移和维持
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    -- NSL
                    s_i2cFsm <= s_SACK_2;
                else
                    -- SM
                    s_i2cFsm <= s_Write;
                end if;
            when s_SACK_2=>  -- 等待和确认从机发送响应信号2
                -- OFL
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_GeneralCnt <= r_GeneralCnt + 1;
                    r_o_SDA <= '1';  -- 释放SDA线，给从机控制权
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then --下降沿，SCL为高，读SDA的值
                    r_GeneralCnt <= 0;
                    case r_i_SDA is
                        when c_SACK =>
                            o_ErrorFlag <= '0';
                            r_IdleFlag <= '1';  -- 检测到有效的从机响应信号，此时传输处于空闲，能够等待新的读写触发信号
                            o_RWOkPulse<='1';
                        when others =>
                            o_ErrorFlag <= '1';
                    end case;
                else
                    null;
                end if;
                -- 状态转移和维持
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                -- NSL
                    case r_i_SDA is
                        when c_SACK =>
                            s_i2cFsm <= s_WritePending;
                        when others =>
                            s_i2cFsm <= s_Stop;
                    end case;
                else
                    -- SM
                    s_i2cFsm <= s_SACK_2;
                end if;
            when s_WritePending =>  -------------------- ** 决定是否还继续写入字节数据，如果还写则结合空闲和WellPulse信号，去操作i_RWTrigger。否在不会再写
                -- OFL
                o_RWOkPulse <= '0';
--                if (r_GeneralCnt < c_Cnt-2) then
--                    r_GeneralCnt <= r_GeneralCnt + 1;
--                else
--                    r_GeneralCnt <= r_GeneralCnt;
--                end if;
                if (r_GeneralCnt < c_Cnt-2 and r_StartPulse = '1') then -- 下一次写操作
                    r_IdleFlag <= '0';  -- i2c控制器忙
                    -- i_RWEN <= '1';
                    r_WriteData <= i_WDataByte;         -- 要写的字节数据存储
                    r_GeneralCnt <= 7;
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then --从机地址或读写类型变了
                        r_AddrCmd <= i_SlaveAddr & i_RW;-- 将从机地址和读写控制位存储
                        r_GeneralCnt <= 0;
                    end if;
                elsif (r_GeneralCnt = c_Cnt-2) then
                    r_GeneralCnt <= 0;
                else
                    r_GeneralCnt <= r_GeneralCnt + 1;
                end if;
                -- 状态转移和维持
                if (r_GeneralCnt < c_Cnt-2 and r_StartPulse = '1') then
                    -- NSL
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then
                        s_i2cFsm <= s_Start;            -- 重新启动流程
                    else
                        s_i2cFsm <= s_Write;            -- 等到了继续写信号
                    end if;
                elsif (r_GeneralCnt = c_Cnt-2) then
                    s_i2cFsm <= s_Stop;                 -- 没等到写信好
                else
                    -- SM
                    s_i2cFsm <= s_WritePending;
                end if;
            when s_Read  =>  --------------------------- ** 主机读从机字节数据
                -- OFL
                if (r_SdaClkRiseEdge = '1') then  -- SCL低电平 约中间位置
                    r_o_SDA <= '1'; -- 主机释放SDA控制权
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt /= 0) then
                    r_ReadData(r_GeneralCnt) <= r_i_SDA;     -- 左移位存储，确保MSB-LSB
                    r_GeneralCnt <= r_GeneralCnt - 1;
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 0) then
                    r_ReadData(r_GeneralCnt) <= r_i_SDA;     -- 左移位存储，确保MSB-LSB
                    o_RWOkPulse <= '1';
                    r_IdleFlag <= '1';
                else
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- 状态转移和维持
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 0) then
                    -- NSL
                    s_i2cFsm <= s_MACK;     -- 主机收到了从机数据，进入对从机做出响应状态
                else
                    -- SM
                    s_i2cFsm <= s_Read;                
                end if;
            when s_MACK  =>  --------------------------- ** 主机给从机响应信号
                -- OFL
                o_RWOkPulse <= '0';
                if (r_GeneralCnt < c_Cnt-2 and r_StartPulse = '1') then -- 下一次读操作确认
                    r_IdleFlag <= '0';  -- i2c控制器忙
                elsif (r_GeneralCnt = c_Cnt-2 or r_IdleFlag = '0') then
                    r_GeneralCnt <= r_GeneralCnt;
                else
                    r_GeneralCnt <= r_GeneralCnt + 1;
                end if;
                
                if (r_SdaClkRiseEdge = '1' and r_IdleFlag = '0') then   -- 主机还继续读取数据，主机给RWEN负脉冲
                    
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then --从机地址或读写类型变了
                        r_AddrCmd <= i_SlaveAddr & i_RW;-- 将从机地址和读写控制位存储
                        r_GeneralCnt <= 0;
                        r_o_SDA <= c_MNACK;      -- 主机发送响应1，从机接收不继续发送数据
                    else
                        r_GeneralCnt <= 7;
                        r_o_SDA <= c_MACK;      -- 主机发送响应0，从机接收后继续发送数据
                    end if;
                elsif (r_SdaClkRiseEdge = '1' and r_IdleFlag /= '0') then -- 主机不再读数据，主机没给负脉冲
                    r_o_SDA <= c_MNACK;     -- 主机发送响应1，从机结束发送数据
                    r_GeneralCnt <= 0;
                else  -- SDA CLK上升沿没来，等待
                    r_o_SDA <= '1';
                end if;
                -- 状态转移和维持
                -- NSL
                if (r_SdaClkRiseEdge = '1' and r_IdleFlag = '0') then   -- 主机还继续读取数据，主机给了负脉冲
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then
                        s_i2cFsm <= s_Start;            -- 重新启动流程
                    else
                        s_i2cFsm <= s_Read;            -- 等到了继续读信号
                    end if;
                elsif (r_SdaClkRiseEdge = '1' and r_IdleFlag /= '0') then -- 主机不再读数据，主机没给RETrigger信号
                    s_i2cFsm <= s_Stop;
                else  -- SDA CLK上升沿没来，等待
                    -- SM
                    s_i2cFsm <= s_MACK;
                end if;
            when s_Stop  =>  --------------------------- ** 主机发送停止信号
                -- OFL
                o_ErrorFlag <= '0';  --决定错误信号的宽度，不屏蔽正脉冲宽度和模块时钟周期一致；屏蔽将在Idle状态清0
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_GeneralCnt <= r_GeneralCnt + 1;
                    r_o_SDA <= not r_SdaClk;
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                    r_o_SCL <= '1';
                    r_IdleFlag <= '1';
                    r_GeneralCnt <= 0;
                else
                    r_o_SCL <= r_o_SCL;
                    r_o_SDA <= r_o_SDA;
                end if;
                -- 状态转移和维持
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                    -- NSL
                    s_i2cFsm <= s_Idle;
                else
                    -- SM
                    s_i2cFsm <= s_Stop;
                end if;
            when others =>
                s_i2cFsm <= s_Idle;
        end case;
        --else
            --null;
        --end if;
    end if;
end process i2c_fsm_proc;
    
end Behavioral;
