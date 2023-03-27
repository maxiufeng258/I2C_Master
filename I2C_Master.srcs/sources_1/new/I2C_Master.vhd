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
        SYS_CLK_VAL_HZ      :   integer := 50_000_000;  -- 50MHz  ϵͳ����ʱ��ֵ ��λ��Hz
        SCL_VAL_HZ          :   integer := 400_000;     -- 400KHz SCL
        I2C_SLAVE_ADDR_LEN  :   integer :=  7           -- I2C�ӻ���ַλ�� 7bit / (10bit������)
    );
    Port (
        i_SysClk    :   in      std_logic;  -- ϵͳʱ��
        i_SysNrst   :   in      std_logic;  -- ϵͳ�첽��λ
        i_EN        :   in      std_logic;  -- ϵͳ����ģ�鹤��ʹ��λ ģ��ʹ�ܣ�1�����ã�0
        
        i_SlaveAddr :   in      std_logic_vector(I2C_SLAVE_ADDR_LEN-1 downto 0);    -- I2C�ӻ���ַ 7bit
        i_WDataByte :   in      std_logic_vector(7 downto 0);
        i_RW        :   in      std_logic;  -- I2C��д����ָʾλ Read��1��Write��0
        i_RWTrigger :   in      std_logic;  -- I2C��д����ʹ��λ IDLEFlag=1��RWWellPulse=1���½��ش���д������������
        
        o_RDataByte :   out     std_logic_vector(7 downto 0);
        o_IdleFlag  :   out     std_logic;  -- I2C���ڿ��б�־λ ���У�1��æ��0
        o_RWOkPulse :   out     std_logic;  -- I2C��д������������־�ź� һ��������
        o_ErrorFlag :   out     std_logic;  -- �����־λ ����1���޴�0
        
        io_SDA      :   inout   std_logic;  -- SDA�������� ˫��
        io_SCL      :   inout   std_logic   -- SCLʱ������ ˫��
    );
end I2C_Master;

architecture Behavioral of I2C_Master is
-- ��������/����
    constant    c_MACK      :   std_logic   :=  '0';    -- ������Ӧ�� Master ACK
    constant    c_MNACK     :   std_logic   :=  '1';    -- ������Ӧ�� Master NACK
    constant    c_SACK      :   std_logic   :=  '0';    -- �ӻ���Ӧ�� Slaver ACK
    constant    c_SNACK     :   std_logic   :=  '1';    -- �ӻ���Ӧ�� Slaver NACK
    constant    c_Cnt       :   integer     :=  (SYS_CLK_VAL_HZ / SCL_VAL_HZ) / 4;    -- �����Ƚ�ֵ ��������SclClk �� SdaClk
-- �Ĵ����ź�����
    signal      r_Cnt       :   integer     :=   0 ;    -- ����ֵ ��������SclClk �� SdaClk
    signal      r_SclClk    :   std_logic   :=  '0';
    signal      r_SdaClk    :   std_logic   :=  '0';
    signal      r_SdaClkSync:   std_logic   :=  '0';    -- r_SdaClkSync���ӳ�һ��
    signal      r_SdaClkFallEdge:std_logic  :=  '0';    -- ��ʱ��Ӧ��r_SclClk�ĸߵ�ƽԼ�м�λ�ô�
    signal      r_SdaClkRiseEdge:std_logic  :=  '0';    -- ��ʱ��Ӧ��r_SclClk�ĵ͵�ƽԼ�м�λ�ô�
    
    signal      r_RWTriggerSync  :   std_logic   :=  '0';    -- i_RWTrigger���ӳ�1��
    signal      r_StartPulse:   std_logic   :=  '0';    -- ����ָʾ����
    
    signal      r_IdleFlag  :   std_logic   :=  '1';
    signal      r_AddrCmd   :   std_logic_vector(7 downto 0) := "00000000"; -- �Ͳ���ַ��RWλ
    signal      r_WriteData :   std_logic_vector(7 downto 0) := "00000000"; -- ��Ŵ����͵��ֽ�����
    signal      r_ReadData  :   std_logic_vector(7 downto 0) := "00000000"; -- ��Ž��յ����ֽ�����
    
    signal      r_o_SDA     :   std_logic   :=  '1';
    signal      r_i_SDA     :   std_logic;
    signal      r_o_SCL     :   std_logic   :=  '1';
    signal      r_i_SCL     :   std_logic;
    
    type        t_i2cFsm    is (s_Idle, s_Start, s_Stop, s_Command, s_SACK_1, s_SACK_2, s_Write, s_Read, s_MACK, s_WritePending);
    signal      s_i2cFsm    :   t_i2cFsm    :=  s_Idle;
    
    signal      r_GeneralCnt:   integer range 0 to 1000 := 0; -- bit���� �� ���صȴ�����

begin
-- ����߼�
    -- ��̬�� SDA �� SCL �˿�
    io_SDA  <= '0' when (r_o_SDA = '0') else 'Z';
    r_i_SDA <= io_SDA;
    io_SCL  <= '0' when (r_o_SCL = '0'  and r_SclClk = '0') else 'Z';
    r_i_SCL <= io_SCL;
    
    -- ����SDA CLK�������أ������ɵ�SCLʱ��Ϊ��ʱ
    r_SdaClkFallEdge <= '1' when (r_SdaClkSync='1' and r_SdaClk='0') else '0';
    r_SdaClkRiseEdge <= '1' when (r_SdaClkSync='0' and r_SdaClk='1') else '0';
    -- ����i_RWEN�źŵ��½��������ź�
    r_StartPulse <= '1' when (r_RWTriggerSync = '0' and i_RWTrigger = '1' and r_IdleFlag = '1') else '0';
    --                      ________________|~~\_______________________
    --                      _________________|~~\______________________
    o_IdleFlag <= r_IdleFlag;
    
    o_RDataByte<= r_ReadData;
-- ʱ���߼�
sclSdaClk_proc: process(i_SysClk, i_SysNrst, i_EN)
begin
    if (i_SysNrst = '0' OR i_EN = '0') then
        r_Cnt        <=   0 ;
        r_SclClk     <=  '0';
        r_SdaClk     <=  '0';
        r_SdaClkSync <=  '0';
        r_RWTriggerSync <= '0';
    elsif (rising_edge(i_SysClk)) then
        r_RWTriggerSync <= i_RWTrigger;   -- ��i_RWEN��һ�ģ�����ȷ��i_RWEN�ĸ����壬��Ϊ���Ƿ�������ݶ�д�����ı�־�ź�
        
        r_SdaClkSync <= r_SdaClk;    -- ��r_SdaClk�ӳ�һ�� ���ں�r_SdaClkSyncȷ��SDA���ݱ仯��λ�ã���SCL�ĸߵ��м�λ�á�
        if (r_Cnt = (c_Cnt*4)-1) then
            r_Cnt <= 0;
        else
            r_Cnt <= r_Cnt + 1;
        end if;
        -- ����SCL_CLK��SDA_CLKʱ�Ӳο��ź�
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
-- ״̬�����ƹ���
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
    
        --if (r_SdaClkRiseEdge = '1') then    -- ϵͳʱ�������� + SDAʱ�������أ�ȷ��SCL�͵�ƽ�м�Ϊ��ʼʱ��
        case s_i2cFsm is
            when s_Idle =>  --��������������������������- ** ����״̬
                -- OFL
                r_o_SCL <= '1';
                r_o_SDA <= '1';
                o_ErrorFlag <= '0';
                o_RWOkPulse <= '0';
                r_GeneralCnt <= 0;
                if (r_StartPulse = '1') then
                    r_IdleFlag <= '0';                  -- ��ʼI2C���̣����ڿ���
                    r_AddrCmd <= i_SlaveAddr & i_RW;    -- ���ӻ���ַ�Ͷ�д����λ�洢
                    r_WriteData <= i_WDataByte;         -- ��Ҫд�������ֽڴ洢
                    -- i_RWEN <= '1';
                else
                    r_IdleFlag <= '1';
                    r_AddrCmd <= "00000000";
                    r_WriteData <= "00000000";
                end if;
                -- ״̬ת�ƺ�ά��
                if (r_StartPulse = '1') then
                    -- NSL
                    s_i2cFsm <= s_Start;
                else
                    -- SM
                    s_i2cFsm <= s_Idle;
                end if;
                
            when s_Start=>  --------------------------- ** I2C������SCL��ʱ SDA�Ӹߵ��ͣ���������
                -- OFL
                -- �ȵ�sda_Clk��������
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_GeneralCnt <= r_GeneralCnt + 1;
                    r_o_SDA <= r_SdaClk;
                    r_o_SCL <= '1';
                -- ���������أ��ȴ��½��ص���
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                    r_o_SCL <= '0';
                    r_o_SDA <= r_SdaClk;
                    r_GeneralCnt <= 7;                  --�¸�״̬�����������ݣ�λ������
                else
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- ״̬ת�ƺ�ά��
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                    s_i2cFsm <= s_Command;
                else
                    s_i2cFsm <= s_Start;
                end if;
            when s_Command =>   ------------------------ ** �������ʹ��豸��ַ+RWλ
                -- OFL
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt /= 0) then
                    r_o_SDA <= r_AddrCmd(r_GeneralCnt); --bit7-1�͵�SDA���
                    r_GeneralCnt <= r_GeneralCnt - 1;
                elsif (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_o_SDA <= r_AddrCmd(r_GeneralCnt); --bit0�͵�SDA���
                else
                    r_o_SDA <= r_o_SDA;
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- ״̬ת�ƺ�ά��
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    -- NSL
                    s_i2cFsm <= s_SACK_1;
                else
                    -- SM
                    s_i2cFsm <= s_Command;
                end if;
            when s_SACK_1 =>    ------------------------ ** �ȴ���ȷ�ϴӻ�������Ӧ�ź�
                -- OFL
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then       -- ȷ��SCL�͵�ƽԼ�м�λ��
                    r_GeneralCnt <= r_GeneralCnt + 1;
                    r_o_SDA <= '1';  -- �ͷ�SDA�ߣ����ӻ�����Ȩ
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then    --�½��أ�SCLΪ��Լ�м�λ�ã���SDA��ֵ
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
                -- ״̬ת�ƺ�ά��
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then
                -- NSL
                    case r_i_SDA is
                        when c_SACK =>
                            if (r_AddrCmd(0) = '0') then -- r_AddrCmd���һλ=0��д�����ֽ�
                                s_i2cFsm <= s_Write;
                            else  -- r_AddrCmd���һλ=1���������ֽ�
                                s_i2cFsm <= s_Read;
                            end if;
                        when others =>
                            s_i2cFsm <= s_Stop;
                    end case;
                else
                    -- SM
                    s_i2cFsm <= s_SACK_1;
                end if;
            when s_Write =>  --------------------------- ** ���ӻ�д�ֽ�����
                -- OFL
                r_IdleFlag <= '0';
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt /= 0) then  -- SCL�͵�ƽ Լ�м�λ��
                    r_o_SDA <= r_WriteData(r_GeneralCnt); --bit7-1�͵�SDA���
                    r_GeneralCnt <= r_GeneralCnt - 1;
                elsif (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_o_SDA <= r_WriteData(r_GeneralCnt); --bit0�͵�SDA���
                else
                    r_o_SDA <= r_o_SDA;
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- ״̬ת�ƺ�ά��
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    -- NSL
                    s_i2cFsm <= s_SACK_2;
                else
                    -- SM
                    s_i2cFsm <= s_Write;
                end if;
            when s_SACK_2=>  -- �ȴ���ȷ�ϴӻ�������Ӧ�ź�2
                -- OFL
                if (r_SdaClkRiseEdge = '1' and r_GeneralCnt = 0) then
                    r_GeneralCnt <= r_GeneralCnt + 1;
                    r_o_SDA <= '1';  -- �ͷ�SDA�ߣ����ӻ�����Ȩ
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 1) then --�½��أ�SCLΪ�ߣ���SDA��ֵ
                    r_GeneralCnt <= 0;
                    case r_i_SDA is
                        when c_SACK =>
                            o_ErrorFlag <= '0';
                            r_IdleFlag <= '1';  -- ��⵽��Ч�Ĵӻ���Ӧ�źţ���ʱ���䴦�ڿ��У��ܹ��ȴ��µĶ�д�����ź�
                            o_RWOkPulse<='1';
                        when others =>
                            o_ErrorFlag <= '1';
                    end case;
                else
                    null;
                end if;
                -- ״̬ת�ƺ�ά��
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
            when s_WritePending =>  -------------------- ** �����Ƿ񻹼���д���ֽ����ݣ������д���Ͽ��к�WellPulse�źţ�ȥ����i_RWTrigger�����ڲ�����д
                -- OFL
                o_RWOkPulse <= '0';
--                if (r_GeneralCnt < c_Cnt-2) then
--                    r_GeneralCnt <= r_GeneralCnt + 1;
--                else
--                    r_GeneralCnt <= r_GeneralCnt;
--                end if;
                if (r_GeneralCnt < c_Cnt-2 and r_StartPulse = '1') then -- ��һ��д����
                    r_IdleFlag <= '0';  -- i2c������æ
                    -- i_RWEN <= '1';
                    r_WriteData <= i_WDataByte;         -- Ҫд���ֽ����ݴ洢
                    r_GeneralCnt <= 7;
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then --�ӻ���ַ���д���ͱ���
                        r_AddrCmd <= i_SlaveAddr & i_RW;-- ���ӻ���ַ�Ͷ�д����λ�洢
                        r_GeneralCnt <= 0;
                    end if;
                elsif (r_GeneralCnt = c_Cnt-2) then
                    r_GeneralCnt <= 0;
                else
                    r_GeneralCnt <= r_GeneralCnt + 1;
                end if;
                -- ״̬ת�ƺ�ά��
                if (r_GeneralCnt < c_Cnt-2 and r_StartPulse = '1') then
                    -- NSL
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then
                        s_i2cFsm <= s_Start;            -- ������������
                    else
                        s_i2cFsm <= s_Write;            -- �ȵ��˼���д�ź�
                    end if;
                elsif (r_GeneralCnt = c_Cnt-2) then
                    s_i2cFsm <= s_Stop;                 -- û�ȵ�д�ź�
                else
                    -- SM
                    s_i2cFsm <= s_WritePending;
                end if;
            when s_Read  =>  --------------------------- ** �������ӻ��ֽ�����
                -- OFL
                if (r_SdaClkRiseEdge = '1') then  -- SCL�͵�ƽ Լ�м�λ��
                    r_o_SDA <= '1'; -- �����ͷ�SDA����Ȩ
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt /= 0) then
                    r_ReadData(r_GeneralCnt) <= r_i_SDA;     -- ����λ�洢��ȷ��MSB-LSB
                    r_GeneralCnt <= r_GeneralCnt - 1;
                elsif (r_SdaClkFallEdge = '1' and r_GeneralCnt = 0) then
                    r_ReadData(r_GeneralCnt) <= r_i_SDA;     -- ����λ�洢��ȷ��MSB-LSB
                    o_RWOkPulse <= '1';
                    r_IdleFlag <= '1';
                else
                    r_GeneralCnt <= r_GeneralCnt;
                end if;
                -- ״̬ת�ƺ�ά��
                if (r_SdaClkFallEdge = '1' and r_GeneralCnt = 0) then
                    -- NSL
                    s_i2cFsm <= s_MACK;     -- �����յ��˴ӻ����ݣ�����Դӻ�������Ӧ״̬
                else
                    -- SM
                    s_i2cFsm <= s_Read;                
                end if;
            when s_MACK  =>  --------------------------- ** �������ӻ���Ӧ�ź�
                -- OFL
                o_RWOkPulse <= '0';
                if (r_GeneralCnt < c_Cnt-2 and r_StartPulse = '1') then -- ��һ�ζ�����ȷ��
                    r_IdleFlag <= '0';  -- i2c������æ
                elsif (r_GeneralCnt = c_Cnt-2 or r_IdleFlag = '0') then
                    r_GeneralCnt <= r_GeneralCnt;
                else
                    r_GeneralCnt <= r_GeneralCnt + 1;
                end if;
                
                if (r_SdaClkRiseEdge = '1' and r_IdleFlag = '0') then   -- ������������ȡ���ݣ�������RWEN������
                    
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then --�ӻ���ַ���д���ͱ���
                        r_AddrCmd <= i_SlaveAddr & i_RW;-- ���ӻ���ַ�Ͷ�д����λ�洢
                        r_GeneralCnt <= 0;
                        r_o_SDA <= c_MNACK;      -- ����������Ӧ1���ӻ����ղ�������������
                    else
                        r_GeneralCnt <= 7;
                        r_o_SDA <= c_MACK;      -- ����������Ӧ0���ӻ����պ������������
                    end if;
                elsif (r_SdaClkRiseEdge = '1' and r_IdleFlag /= '0') then -- �������ٶ����ݣ�����û��������
                    r_o_SDA <= c_MNACK;     -- ����������Ӧ1���ӻ�������������
                    r_GeneralCnt <= 0;
                else  -- SDA CLK������û�����ȴ�
                    r_o_SDA <= '1';
                end if;
                -- ״̬ת�ƺ�ά��
                -- NSL
                if (r_SdaClkRiseEdge = '1' and r_IdleFlag = '0') then   -- ������������ȡ���ݣ��������˸�����
                    if (r_AddrCmd(7 downto 1) /= i_SlaveAddr or r_AddrCmd(0) /= i_RW) then
                        s_i2cFsm <= s_Start;            -- ������������
                    else
                        s_i2cFsm <= s_Read;            -- �ȵ��˼������ź�
                    end if;
                elsif (r_SdaClkRiseEdge = '1' and r_IdleFlag /= '0') then -- �������ٶ����ݣ�����û��RETrigger�ź�
                    s_i2cFsm <= s_Stop;
                else  -- SDA CLK������û�����ȴ�
                    -- SM
                    s_i2cFsm <= s_MACK;
                end if;
            when s_Stop  =>  --------------------------- ** ��������ֹͣ�ź�
                -- OFL
                o_ErrorFlag <= '0';  --���������źŵĿ�ȣ��������������Ⱥ�ģ��ʱ������һ�£����ν���Idle״̬��0
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
                -- ״̬ת�ƺ�ά��
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
