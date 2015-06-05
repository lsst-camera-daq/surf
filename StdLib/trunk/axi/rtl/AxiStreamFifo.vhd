-------------------------------------------------------------------------------
-- Title      : AXI Stream FIFO / Re-sizer
-- Project    : General Purpose Core
-------------------------------------------------------------------------------
-- File       : AxiStreamFifo.vhd
-- Author     : Ryan Herbst, rherbst@slac.stanford.edu
-- Created    : 2014-04-25
-- Last update: 2015-06-03
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- Block to serve as an async FIFO for AXI Streams. This block also allows the
-- bus to be compress/expanded, allowing different standard sizes on each side
-- of the FIFO. Re-sizing is always little endian. 
-------------------------------------------------------------------------------
-- Copyright (c) 2014 by Ryan Herbst. All rights reserved.
-------------------------------------------------------------------------------
-- Modification history:
-- 04/25/2014: created.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiLitePkg.all;

entity AxiStreamFifo is
   generic (

      -- General Configurations
      TPD_G               : time                       := 1 ns;
      INT_PIPE_STAGES_G   : natural range 0 to 16      := 1;  -- Internal FIFO setting
      PIPE_STAGES_G       : natural range 0 to 16      := 0;
      SLAVE_READY_EN_G    : boolean                    := true;
      VALID_THOLD_G       : integer range 0 to (2**24) := 1;  -- =1 = normal operation
                                                              -- =0 = only when frame ready
                                                              -- >1 = only when frame ready or # entries
      -- FIFO configurations
      BRAM_EN_G           : boolean                    := true;
      XIL_DEVICE_G        : string                     := "7SERIES";
      USE_BUILT_IN_G      : boolean                    := false;
      GEN_SYNC_FIFO_G     : boolean                    := false;
      ALTERA_SYN_G        : boolean                    := false;
      ALTERA_RAM_G        : string                     := "M9K";
      CASCADE_SIZE_G      : integer range 1 to (2**24) := 1;
      FIFO_ADDR_WIDTH_G   : integer range 4 to 48      := 9;
      FIFO_FIXED_THRESH_G : boolean                    := true;
      FIFO_PAUSE_THRESH_G : integer range 1 to (2**24) := 1;

      -- Index = 0 is output, index = n is input
      CASCADE_PAUSE_SEL_G : integer range 0 to (2**24) := 0;

      -- AXI Stream Port Configurations
      SLAVE_AXI_CONFIG_G  : AxiStreamConfigType := AXI_STREAM_CONFIG_INIT_C;
      MASTER_AXI_CONFIG_G : AxiStreamConfigType := AXI_STREAM_CONFIG_INIT_C
      );
   port (

      -- Slave Port
      sAxisClk    : in  sl;
      sAxisRst    : in  sl;
      sAxisMaster : in  AxiStreamMasterType;
      sAxisSlave  : out AxiStreamSlaveType;
      sAxisCtrl   : out AxiStreamCtrlType;

      -- FIFO status & config , synchronous to sAxisClk
      fifoPauseThresh : in slv(FIFO_ADDR_WIDTH_G-1 downto 0) := (others => '1');

      -- Master Port
      mAxisClk    : in  sl;
      mAxisRst    : in  sl;
      mAxisMaster : out AxiStreamMasterType;
      mAxisSlave  : in  AxiStreamSlaveType;

      -- Option AXI-Lite interface
      axilClk         : in  sl                     := '0';
      axilRst         : in  sl                     := '1';
      axilReadMaster  : in  AxiLiteReadMasterType  := AXI_LITE_READ_MASTER_INIT_C;
      axilReadSlave   : out AxiLiteReadSlaveType;
      axilWriteMaster : in  AxiLiteWriteMasterType := AXI_LITE_WRITE_MASTER_INIT_C;
      axilWriteSlave  : out AxiLiteWriteSlaveType
      );
end AxiStreamFifo;

architecture rtl of AxiStreamFifo is

   -- Use wider of two interfaces
   constant DATA_BYTES_C : integer := maximum(SLAVE_AXI_CONFIG_G.TDATA_BYTES_C, MASTER_AXI_CONFIG_G.TDATA_BYTES_C);
   constant DATA_BITS_C  : integer := (DATA_BYTES_C * 8);

   -- Use SLAVE TKEEP Mode
   constant KEEP_MODE_C : TKeepModeType := SLAVE_AXI_CONFIG_G.TKEEP_MODE_C;
   constant KEEP_BITS_C : integer := ite(KEEP_MODE_C = TKEEP_NORMAL_C, DATA_BYTES_C,
                                         ite(KEEP_MODE_C = TKEEP_COMP_C, bitSize(DATA_BYTES_C-1), 0));

   -- User user bit mode of slave
   constant USER_MODE_C : TUserModeType := SLAVE_AXI_CONFIG_G.TUSER_MODE_C;

   -- Use whichever interface has the least number of user bits
   constant SLAVE_USER_BITS_C  : integer := SLAVE_AXI_CONFIG_G.TUSER_BITS_C;
   constant MASTER_USER_BITS_C : integer := MASTER_AXI_CONFIG_G.TUSER_BITS_C;
   constant FIFO_USER_BITS_C   : integer := minimum(SLAVE_USER_BITS_C, MASTER_USER_BITS_C);

   constant FIFO_USER_TOT_C : integer := ite(USER_MODE_C = TUSER_FIRST_LAST_C, FIFO_USER_BITS_C*2,
                                             ite(USER_MODE_C = TUSER_LAST_C, FIFO_USER_BITS_C,
                                                 DATA_BYTES_C * FIFO_USER_BITS_C));

   -- Use SLAVE settings for strobe, dest and ID bit values
   constant STRB_BITS_C : integer := ite(SLAVE_AXI_CONFIG_G.TSTRB_EN_C, DATA_BYTES_C, 0);
   constant DEST_BITS_C : integer := SLAVE_AXI_CONFIG_G.TDEST_BITS_C;
   constant ID_BITS_C   : integer := SLAVE_AXI_CONFIG_G.TID_BITS_C;

   constant FIFO_BITS_C : integer := 1 + DATA_BITS_C + KEEP_BITS_C + FIFO_USER_TOT_C + STRB_BITS_C + DEST_BITS_C + ID_BITS_C;

   constant WR_BYTES_C : integer := SLAVE_AXI_CONFIG_G.TDATA_BYTES_C;
   constant RD_BYTES_C : integer := MASTER_AXI_CONFIG_G.TDATA_BYTES_C;

   -- Convert record to slv
   function iAxiToSlv (din : AxiStreamMasterType) return slv is
      variable retValue : slv(FIFO_BITS_C-1 downto 0) := (others => '0');
      variable i        : integer                     := 0;
   begin

      -- init, pass last
      assignSlv(i, retValue, din.tLast);

      -- Pack data
      assignSlv(i, retValue, din.tData(DATA_BITS_C-1 downto 0));

      -- Pack keep
      if KEEP_MODE_C = TKEEP_NORMAL_C then
         assignSlv(i, retValue, din.tKeep(KEEP_BITS_C-1 downto 0));
      elsif KEEP_MODE_C = TKEEP_COMP_C then
         assignSlv(i, retValue, onesCount(din.tKeep(DATA_BYTES_C-1 downto 1)));  -- Assume lsb is present
      end if;

      -- Pack user bits
      if USER_MODE_C = TUSER_FIRST_LAST_C then
         assignSlv(i, retValue, resizeSlv(axiStreamGetUserField(SLAVE_AXI_CONFIG_G, din, 0), FIFO_USER_BITS_C));  -- First byte
         assignSlv(i, retValue, resizeSlv(axiStreamGetUserField(SLAVE_AXI_CONFIG_G, din, -1), FIFO_USER_BITS_C));  -- Last valid byte

      elsif USER_MODE_C = TUSER_LAST_C then
         assignSlv(i, retValue, resizeSlv(axiStreamGetUserField(SLAVE_AXI_CONFIG_G, din, -1), FIFO_USER_BITS_C));  -- Last valid byte

      else
         for j in 0 to DATA_BYTES_C-1 loop
            assignSlv(i, retValue, resizeSlv(axiStreamGetUserField(SLAVE_AXI_CONFIG_G, din, j), FIFO_USER_BITS_C));
         end loop;
      end if;

      -- Strobe is optional
      if STRB_BITS_C > 0 then
         assignSlv(i, retValue, din.tStrb(STRB_BITS_C-1 downto 0));
      end if;

      -- Dest is optional
      if DEST_BITS_C > 0 then
         assignSlv(i, retValue, din.tDest(DEST_BITS_C-1 downto 0));
      end if;

      -- Id is optional
      if ID_BITS_C > 0 then
         assignSlv(i, retValue, din.tId(ID_BITS_C-1 downto 0));
      end if;

      return(retValue);

   end function;

   -- Convert slv to record
   procedure iSlvToAxi (din     : in    slv(FIFO_BITS_C-1 downto 0);
                        valid   : in    sl;
                        master  : inout AxiStreamMasterType;
                        byteCnt : inout integer) is
      variable i    : integer := 0;
      variable user : slv(FIFO_USER_BITS_C-1 downto 0);
   begin

      master := AXI_STREAM_MASTER_INIT_C;

      -- Set valid, 
      master.tValid := valid;

      -- Set last
      assignRecord(i, din, master.tLast);

      -- Get data
      assignRecord(i, din, master.tData(DATA_BITS_C-1 downto 0));

      -- Get keep bits
      if KEEP_MODE_C = TKEEP_NORMAL_C then
         assignRecord(i, din, master.tKeep(KEEP_BITS_C-1 downto 0));
         byteCnt := conv_integer(onesCount(master.tKeep(KEEP_BITS_C-1 downto 0)));
      elsif KEEP_MODE_C = TKEEP_COMP_C then
         byteCnt                               := conv_integer(din((KEEP_BITS_C+i)-1 downto i)) + 1;
         master.tKeep(DATA_BYTES_C-1 downto 0) := (others => '0');
         master.tKeep(byteCnt-1 downto 0)      := (others => '1');
         i                                     := i + KEEP_BITS_C;
      else
         byteCnt := DATA_BYTES_C;
         i       := i + KEEP_BITS_C;
      end if;

      -- get user bits
      if USER_MODE_C = TUSER_FIRST_LAST_C then
         assignRecord(i, din, user);
         axiStreamSetUserField (MASTER_AXI_CONFIG_G, master, resizeSlv(user, MASTER_USER_BITS_C), 0);  -- First byte

         assignRecord(i, din, user);
         axiStreamSetUserField (MASTER_AXI_CONFIG_G, master, resizeSlv(user, MASTER_USER_BITS_C), -1);  -- Last valid byte

      elsif USER_MODE_C = TUSER_LAST_C then
         assignRecord(i, din, user);
         axiStreamSetUserField (MASTER_AXI_CONFIG_G, master, resizeSlv(user, MASTER_USER_BITS_C), -1);  -- Last valid byte

      else
         for j in 0 to DATA_BYTES_C-1 loop
            assignRecord(i, din, user);
            axiStreamSetUserField (MASTER_AXI_CONFIG_G, master, resizeSlv(user, MASTER_USER_BITS_C), j);
         end loop;
      end if;

      -- Strobe is optional
      if STRB_BITS_C > 0 then
         assignRecord(i, din, master.tStrb(STRB_BITS_C-1 downto 0));
      end if;

      -- Dest is optional
      if DEST_BITS_C > 0 then
         assignRecord(i, din, master.tDest(DEST_BITS_C-1 downto 0));
      end if;

      -- ID is optional
      if ID_BITS_C > 0 then
         assignRecord(i, din, master.tId(ID_BITS_C-1 downto 0));
      end if;

   end iSlvToAxi;

   ----------------
   -- Write Signals
   ----------------
   constant WR_LOGIC_EN_C : boolean := (WR_BYTES_C < RD_BYTES_C);
   constant WR_SIZE_C     : integer := ite(WR_LOGIC_EN_C, RD_BYTES_C / WR_BYTES_C, 1);

   type WrRegType is record
      count    : slv(bitSize(WR_SIZE_C)-1 downto 0);
      wrMaster : AxiStreamMasterType;
   end record WrRegType;

   constant WR_REG_INIT_C : WrRegType := (
      count    => (others => '0'),
      wrMaster => AXI_STREAM_MASTER_INIT_C);

   signal wrR, wrRin    : WrRegType := WR_REG_INIT_C;
   signal sLocAxisCtrl  : AxiStreamCtrlType;
   signal sLocAxisSlave : AxiStreamSlaveType;

   ----------------
   -- FIFO Signals
   ----------------
   signal fifoDin       : slv(FIFO_BITS_C-1 downto 0);
   signal fifoWrite     : sl;
   signal fifoWriteLast : sl;
   signal fifoWrCount   : slv(FIFO_ADDR_WIDTH_G-1 downto 0);
   signal fifoRdCount   : slv(FIFO_ADDR_WIDTH_G-1 downto 0);
   signal fifoAFull     : sl;
   signal fifoFull      : sl;
   signal fifoReady     : sl;
   signal fifoPFull     : sl;
   signal fifoPFullVec  : slv(CASCADE_SIZE_G-1 downto 0);
   signal fifoDout      : slv(FIFO_BITS_C-1 downto 0);
   signal fifoRead      : sl;
   signal fifoReadLast  : sl;
   signal fifoValidInt  : sl;
   signal fifoValid     : sl;
   signal fifoValidLast : sl;
   signal fifoInFrame   : sl;

   ---------------
   -- Read Signals
   ---------------
   constant RD_LOGIC_EN_C : boolean := (RD_BYTES_C < WR_BYTES_C);
   constant RD_SIZE_C     : integer := ite(RD_LOGIC_EN_C, WR_BYTES_C / RD_BYTES_C, 1);

   type RdRegType is record
      count    : slv(bitSize(RD_SIZE_C)-1 downto 0);
      bytes    : slv(bitSize(DATA_BYTES_C)-1 downto 0);
      rdMaster : AxiStreamMasterType;
      ready    : sl;
   end record RdRegType;

   constant RD_REG_INIT_C : RdRegType := (
      count    => (others => '0'),
      bytes    => conv_std_logic_vector(RD_BYTES_C, bitSize(DATA_BYTES_C)),
      rdMaster => AXI_STREAM_MASTER_INIT_C,
      ready    => '0'
      );

   signal rdR, rdRin : RdRegType := RD_REG_INIT_C;

   ---------------
   -- Sync Signals
   ---------------
   signal axisMaster : AxiStreamMasterType;
   signal axisSlave  : AxiStreamSlaveType;

   ---------------
   -- Debug Signals
   ---------------
   type AxilRegType is record
      test           : slv(31 downto 0);
      countReset     : sl;
      fifoWrCountMax : slv(FIFO_ADDR_WIDTH_G-1 downto 0);
      tLastCount     : slv(31 downto 0);
      pauseLast      : sl;
      pauseCount     : slv(31 downto 0);
      overflowLast   : sl;
      overflowCount  : slv(31 downto 0);
      axilReadSlave  : AxiLiteReadSlaveType;
      axilWriteSlave : AxiLiteWriteSlaveType;
   end record AxilRegType;

   constant AXIL_REG_INIT_C : AxilRegType := (
      test           => (others => '0'),
      countReset     => '0',
      fifoWrCountMax => (others => '0'),
      tLastCount     => (others => '0'),
      pauseLast      => '0',
      pauseCount     => (others => '0'),
      overflowLast   => '0',
      overflowCount  => (others => '0'),
      axilReadSlave  => AXI_LITE_READ_SLAVE_INIT_C,
      axilWriteSlave => AXI_LITE_WRITE_SLAVE_INIT_C);

   signal axilR, axilRin : AxilRegType := AXIL_REG_INIT_C;

   signal locAxilReadMaster  : AxiLiteReadMasterType;
   signal locAxilReadSlave   : AxiLiteReadSlaveType;
   signal locAxilWriteMaster : AxiLiteWriteMasterType;
   signal locAxilWriteSlave  : AxiLiteWriteSlaveType;

begin

   assert ((SLAVE_AXI_CONFIG_G.TDATA_BYTES_C >= MASTER_AXI_CONFIG_G.TDATA_BYTES_C and
            SLAVE_AXI_CONFIG_G.TDATA_BYTES_C mod MASTER_AXI_CONFIG_G.TDATA_BYTES_C = 0) or
           (MASTER_AXI_CONFIG_G.TDATA_BYTES_C >= SLAVE_AXI_CONFIG_G.TDATA_BYTES_C and
            MASTER_AXI_CONFIG_G.TDATA_BYTES_C mod SLAVE_AXI_CONFIG_G.TDATA_BYTES_C = 0))
      report "Data widths must be even number multiples of each other" severity failure;

   -------------------------
   -- Write Logic
   -------------------------
   wrComb : process (fifoReady, sAxisMaster, sLocAxisCtrl, sLocAxisSlave, wrR) is
      variable v   : WrRegType;
      variable idx : integer;

      
      
   begin
      v   := wrR;
      idx := conv_integer(wrR.count);

      -- Advance pipeline
      if fifoReady = '1' then

         -- init when count = 0
         if (wrR.count = 0) then
            v.wrMaster.tKeep := (others => '0');
            v.wrMaster.tData := (others => '0');
            v.wrMaster.tStrb := (others => '0');
            v.wrMaster.tUser := (others => '0');
         end if;

         v.wrMaster.tData((WR_BYTES_C*8*idx)+((WR_BYTES_C*8)-1) downto (WR_BYTES_C*8*idx)) := sAxisMaster.tData((WR_BYTES_C*8)-1 downto 0);
         v.wrMaster.tStrb((WR_BYTES_C*idx)+(WR_BYTES_C-1) downto (WR_BYTES_C*idx))         := sAxisMaster.tStrb(WR_BYTES_C-1 downto 0);
         v.wrMaster.tKeep((WR_BYTES_C*idx)+(WR_BYTES_C-1) downto (WR_BYTES_C*idx))         := sAxisMaster.tKeep(WR_BYTES_C-1 downto 0);

         v.wrMaster.tUser((WR_BYTES_C*SLAVE_USER_BITS_C*idx)+((WR_BYTES_C*SLAVE_USER_BITS_C)-1) downto (WR_BYTES_C*SLAVE_USER_BITS_C*idx))
            := sAxisMaster.tUser((WR_BYTES_C*SLAVE_USER_BITS_C)-1 downto 0);

         v.wrMaster.tDest := sAxisMaster.tDest;
         v.wrMaster.tId   := sAxisMaster.tId;
         v.wrMaster.tLast := sAxisMaster.tLast;

         -- Determine end mode, valid and ready
         if sAxisMaster.tValid = '1' then
            if (wrR.count = (WR_SIZE_C-1) or sAxisMaster.tLast = '1') then
               v.wrMaster.tValid := '1';
               v.count           := (others => '0');
            else
               v.wrMaster.tValid := '0';
               v.count           := wrR.count + 1;
            end if;
         else
            v.wrMaster.tValid := '0';
         end if;
      end if;

      -- Write logic enabled
      if WR_LOGIC_EN_C then
         fifoDin       <= iAxiToSlv(wrR.wrMaster);
         fifoWrite     <= wrR.wrMaster.tValid and fifoReady;
         fifoWriteLast <= wrR.wrMaster.tValid and fifoReady and wrR.wrMaster.tLast;

      -- Bypass write logic
      else
         fifoDin       <= iAxiToSlv(sAxisMaster);
         fifoWrite     <= sAxisMaster.tValid and fifoReady;
         fifoWriteLast <= sAxisMaster.tValid and fifoReady and sAxisMaster.tLast;
      end if;

      sLocAxisSlave.tReady <= fifoReady;
      sAxisCtrl            <= sLocAxisCtrl;
      sAxisSlave           <= sLocAxisSlave;

      wrRin <= v;
   end process wrComb;



   wrSeq : process (sAxisClk) is
   begin
      if (rising_edge(sAxisClk)) then
         if sAxisRst = '1' or WR_LOGIC_EN_C = false then
            wrR <= WR_REG_INIT_C after TPD_G;
         else
            wrR <= wrRin after TPD_G;
         end if;
      end if;
   end process wrSeq;


   -------------------------
   -- FIFO
   -------------------------

   -- Pause generation
   process (sAxisClk, fifoPFull, fifoPFullVec) is
   begin
      if FIFO_FIXED_THRESH_G then
         sLocAxisCtrl.pause <= fifoPFullVec(CASCADE_PAUSE_SEL_G) after TPD_G;
      elsif (rising_edge(sAxisClk)) then
         if sAxisRst = '1' or fifoWrCount >= fifoPauseThresh then
            sLocAxisCtrl.pause <= '1' after TPD_G;
         else
            sLocAxisCtrl.pause <= '0' after TPD_G;
         end if;
      end if;
   end process;

   -- Is ready enabled?
   fifoReady <= (not fifoAFull) when SLAVE_READY_EN_G else '1';

   U_Fifo : entity work.FifoCascade
      generic map (
         TPD_G              => TPD_G,
         CASCADE_SIZE_G     => CASCADE_SIZE_G,
         LAST_STAGE_ASYNC_G => true,
         PIPE_STAGES_G      => INT_PIPE_STAGES_G,
         RST_POLARITY_G     => '1',
         RST_ASYNC_G        => false,
         GEN_SYNC_FIFO_G    => GEN_SYNC_FIFO_G,
         BRAM_EN_G          => BRAM_EN_G,
         FWFT_EN_G          => true,
         USE_DSP48_G        => "no",
         ALTERA_SYN_G       => ALTERA_SYN_G,
         ALTERA_RAM_G       => ALTERA_RAM_G,
         USE_BUILT_IN_G     => USE_BUILT_IN_G,
         XIL_DEVICE_G       => XIL_DEVICE_G,
         SYNC_STAGES_G      => 3,
         DATA_WIDTH_G       => FIFO_BITS_C,
         ADDR_WIDTH_G       => FIFO_ADDR_WIDTH_G,
         INIT_G             => "0",
         FULL_THRES_G       => FIFO_PAUSE_THRESH_G,
         EMPTY_THRES_G      => 1
         )
      port map (
         rst           => sAxisRst,
         wr_clk        => sAxisClk,
         wr_en         => fifoWrite,
         din           => fifoDin,
         wr_data_count => fifoWrCount,
         wr_ack        => open,
         overflow      => sLocAxisCtrl.overflow,
         prog_full     => fifoPFull,
         progFullVec   => fifoPFullVec,
         almost_full   => fifoAFull,
         full          => fifoFull,
         not_full      => open,
         rd_clk        => mAxisClk,
         rd_en         => fifoRead,
         dout          => fifoDout,
         rd_data_count => fifoRdCount,
         valid         => fifoValidInt,
         underflow     => open,
         prog_empty    => open,
         almost_empty  => open,
         empty         => open
         );

   U_LastFifoEnGen : if VALID_THOLD_G /= 1 generate

      U_LastFifo : entity work.FifoCascade
         generic map (
            TPD_G              => TPD_G,
            CASCADE_SIZE_G     => CASCADE_SIZE_G,
            LAST_STAGE_ASYNC_G => true,
            PIPE_STAGES_G      => INT_PIPE_STAGES_G,
            RST_POLARITY_G     => '1',
            RST_ASYNC_G        => false,
            GEN_SYNC_FIFO_G    => GEN_SYNC_FIFO_G,
            BRAM_EN_G          => false,
            FWFT_EN_G          => true,
            USE_DSP48_G        => "no",
            ALTERA_SYN_G       => ALTERA_SYN_G,
            ALTERA_RAM_G       => ALTERA_RAM_G,
            USE_BUILT_IN_G     => false,
            XIL_DEVICE_G       => XIL_DEVICE_G,
            SYNC_STAGES_G      => 3,
            DATA_WIDTH_G       => 1,
            ADDR_WIDTH_G       => FIFO_ADDR_WIDTH_G,
            INIT_G             => "0",
            FULL_THRES_G       => 1,
            EMPTY_THRES_G      => 1
            )
         port map (
            rst           => sAxisRst,
            wr_clk        => sAxisClk,
            wr_en         => fifoWriteLast,
            din           => (others => '0'),
            wr_data_count => open,
            wr_ack        => open,
            overflow      => open,
            prog_full     => open,
            almost_full   => open,
            full          => open,
            not_full      => open,
            rd_clk        => mAxisClk,
            rd_en         => fifoReadLast,
            dout          => open,
            rd_data_count => open,
            valid         => fifoValidLast,
            underflow     => open,
            prog_empty    => open,
            almost_empty  => open,
            empty         => open
            );

      process (mAxisClk) is
      begin
         if (rising_edge(mAxisClk)) then
            if mAxisRst = '1' or fifoReadLast = '1' then
               fifoInFrame <= '0' after TPD_G;
            elsif fifoValidLast = '1' or (VALID_THOLD_G /= 0 and fifoRdCount >= VALID_THOLD_G) then
               fifoInFrame <= '1' after TPD_G;
            end if;
         end if;
      end process;

      fifoValid <= fifoValidInt and fifoInFrame;

   end generate;

   U_LastFifoDisGen : if VALID_THOLD_G = 1 generate
      fifoValidLast <= '0';
      fifoValid     <= fifoValidInt;
      fifoInFrame   <= '0';
   end generate;


   -------------------------
   -- Read Logic
   -------------------------

   rdComb : process (rdR, fifoDout, fifoValid, axisSlave) is
      variable v          : RdRegType;
      variable idx        : integer;
      variable byteCnt    : integer;
      variable fifoMaster : AxiStreamMasterType;
   begin
      v   := rdR;
      idx := conv_integer(rdR.count);

      iSlvToAxi (fifoDout, fifoValid, fifoMaster, byteCnt);

      -- Advance pipeline
      if axisSlave.tReady = '1' or rdR.rdMaster.tValid = '0' then
         v.rdMaster := AXI_STREAM_MASTER_INIT_C;

         v.rdMaster.tData((RD_BYTES_C*8)-1 downto 0) := fifoMaster.tData((RD_BYTES_C*8*idx)+((RD_BYTES_C*8)-1) downto (RD_BYTES_C*8*idx));
         v.rdMaster.tStrb(RD_BYTES_C-1 downto 0)     := fifoMaster.tStrb((RD_BYTES_C*idx)+(RD_BYTES_C-1) downto (RD_BYTES_C*idx));
         v.rdMaster.tKeep(RD_BYTES_C-1 downto 0)     := fifoMaster.tKeep((RD_BYTES_C*idx)+(RD_BYTES_C-1) downto (RD_BYTES_C*idx));

         v.rdMaster.tUser((RD_BYTES_C*MASTER_USER_BITS_C)-1 downto 0)
            := fifoMaster.tUser((RD_BYTES_C*MASTER_USER_BITS_C*idx)+((RD_BYTES_C*MASTER_USER_BITS_C)-1) downto (RD_BYTES_C*MASTER_USER_BITS_C*idx));

         v.rdMaster.tDest := fifoMaster.tDest;
         v.rdMaster.tId   := fifoMaster.tId;

         -- Reached end of fifo data or no more valid bytes in last word
         if fifoMaster.tValid = '1' then
            if (rdR.count = (RD_SIZE_C-1)) or ((rdR.bytes >= byteCnt) and (fifoMaster.tLast = '1')) then
               v.count          := (others => '0');
               v.bytes          := conv_std_logic_vector(RD_BYTES_C, bitSize(DATA_BYTES_C));
               v.ready          := '1';
               v.rdMaster.tLast := fifoMaster.tLast;
            else
               v.count          := rdR.count + 1;
               v.bytes          := rdR.bytes + RD_BYTES_C;
               v.ready          := '0';
               v.rdMaster.tLast := '0';
            end if;
         end if;

         -- Drop transfers with no tKeep bits set, except on tLast
         v.rdMaster.tValid := fifoMaster.tValid and
                              (uOr(v.rdMaster.tKeep(RD_BYTES_C-1 downto 0)) or
                               v.rdMaster.tLast);

      else
         v.ready := '0';
      end if;

      rdRin <= v;

      -- Read logic enabled
      if RD_LOGIC_EN_C then
         axisMaster   <= rdR.rdMaster;
         fifoRead     <= v.ready and fifoValid;
         fifoReadLast <= v.ready and fifoValid and fifoMaster.tLast;

      -- Bypass read logic
      else
         axisMaster   <= fifoMaster;
         fifoRead     <= axisSlave.tReady and fifoValid;
         fifoReadLast <= axisSlave.tReady and fifoValid and fifoMaster.tLast;
      end if;
      
   end process rdComb;

   -- If fifo is asynchronous, must use async reset on rd side.
   rdSeq : process (mAxisClk) is
   begin
      if (rising_edge(mAxisClk)) then
         if mAxisRst = '1' or RD_LOGIC_EN_C = false then
            rdR <= RD_REG_INIT_C after TPD_G;
         else
            rdR <= rdRin after TPD_G;
         end if;
      end if;
   end process rdSeq;


   -------------------------
   -- Pipeline Logic
   -------------------------

   U_Pipe : entity work.AxiStreamPipeline
      generic map (
         TPD_G         => TPD_G,
         PIPE_STAGES_G => PIPE_STAGES_G
         )
      port map (
         -- Clock and Reset
         axisClk     => mAxisClk,
         axisRst     => mAxisRst,
         -- Slave Port
         sAxisMaster => axisMaster,
         sAxisSlave  => axisSlave,
         -- Master Port
         mAxisMaster => mAxisMaster,
         mAxisSlave  => mAxisSlave);

   -------------------------------------------------------------------------------------------------
   -- Option AXI-Lite interface for debug
   -- Convert to use slave clock
   -------------------------------------------------------------------------------------------------
   AxiLiteAsync_1 : entity work.AxiLiteAsync
      generic map (
         TPD_G           => TPD_G,
         NUM_ADDR_BITS_G => 32)
      port map (
         sAxiClk         => axilClk,
         sAxiClkRst      => axilRst,
         sAxiReadMaster  => axilReadMaster,
         sAxiReadSlave   => axilReadSlave,
         sAxiWriteMaster => axilWriteMaster,
         sAxiWriteSlave  => axilWriteSlave,
         mAxiClk         => sAxisClk,
         mAxiClkRst      => sAxisRst,
         mAxiReadMaster  => locAxilReadMaster,
         mAxiReadSlave   => locAxilReadSlave,
         mAxiWriteMaster => locAxilWriteMaster,
         mAxiWriteSlave  => locAxilWriteSlave);

--   locAxilWriteMaster <= axilWriteMaster;
--   locAxilReadMaster  <= axilReadMaster;
--   axilWriteSlave     <= locAxilWriteSlave;
--   axilReadSlave      <= locAxilReadSlave;


   axilComb : process (axilR, fifoFull, fifoWrCount, locAxilReadMaster, locAxilWriteMaster,
                       sAxisMaster, sAxisRst, sLocAxisCtrl, sLocAxisSlave) is
      variable v         : AxilRegType;
      variable axiStatus : AxiLiteStatusType;

      -- Wrapper procedures to make calls cleaner.
      procedure axiSlaveRegisterW (addr : in slv; offset : in integer; reg : inout slv; cA : in boolean := false; cV : in slv := "0") is
      begin
         axiSlaveRegister(locAxilWriteMaster, locAxilReadMaster, v.axilWriteSlave, v.axilReadSlave, axiStatus, addr, offset, reg, cA, cV);
      end procedure;

      procedure axiSlaveRegisterR (addr : in slv; offset : in integer; reg : in slv) is
      begin
         axiSlaveRegister(locAxilReadMaster, v.axilReadSlave, axiStatus, addr, offset, reg);
      end procedure;

      procedure axiSlaveRegisterW (addr : in slv; offset : in integer; reg : inout sl) is
      begin
         axiSlaveRegister(locAxilWriteMaster, locAxilReadMaster, v.axilWriteSlave, v.axilReadSlave, axiStatus, addr, offset, reg);
      end procedure;

      procedure axiSlaveRegisterR (addr : in slv; offset : in integer; reg : in sl) is
      begin
         axiSlaveRegister(locAxilReadMaster, v.axilReadSlave, axiStatus, addr, offset, reg);
      end procedure;

      procedure axiSlaveDefault (
         axiResp : in slv(1 downto 0)) is
      begin
         axiSlaveDefault(locAxilWriteMaster, locAxilReadMaster, v.axilWriteSlave, v.axilReadSlave, axiStatus, axiResp);
      end procedure;
   begin


      ----------------------------------------------------------------------------------------------
      -- Debug logic
      ----------------------------------------------------------------------------------------------
      if (fifoWrCount > axilR.fifoWrCountMax and fifoFull = '0') then
         v.fifoWrCountMax := fifoWrCount;
      end if;

      if (sAxisMaster.tValid = '1' and sAxisMaster.tLast = '1' and sLocAxisSlave.tReady = '1') then
         v.tLastCount := axilR.tLastCount + 1;
      end if;

      v.pauseLast := sLocAxisCtrl.pause;
      if (sLocAxisCtrl.pause = '1' and axilR.pauseLast = '0') then
         v.pauseCount := axilR.pauseCount + 1;
      end if;

      v.overflowLast := sLocAxisCtrl.overflow;
      if (sLocAxisCtrl.overflow = '1' and axilR.overflowLast = '0') then
         v.overflowCount := axilR.overflowCount + 1;
      end if;

      if (axilR.countReset = '1') then
         v.fifoWrCountMax := (others => '0');
         v.tLastCount     := (others => '0');
         v.pauseCount     := (others => '0');
         v.overflowCount  := (others => '0');
      end if;
      v.countReset := '0';

      axiSlaveWaitTxn(locAxilWriteMaster, locAxilReadMaster, v.axilWriteSlave, v.axilReadSlave, axiStatus);

      if (axiStatus.writeEnable = '1') then
         -- Send Axi response
         case locAxilWriteMaster.awaddr(7 downto 0) is
            when X"00" =>
               v.countReset := locAxilWriteMaster.wdata(0);
            when others => null;
         end case;
         axiSlaveWriteResponse(v.axilWriteSlave);
      end if;

      if (axiStatus.readEnable = '1') then
         -- Decode address and assign read data
         v.axilReadSlave.rdata := (others => '0');
         case locAxilReadMaster.araddr(7 downto 0) is
            when X"04" =>
               v.axilReadSlave.rdata(fifoWrCount'length-1 downto 0) := fifoWrCount;
            when X"08" =>
               v.axilReadSlave.rdata(axilR.fifoWrCountMax'range) := axilR.fifoWrCountMax;
            when X"0C" =>
               v.axilReadSlave.rdata(axilR.tLastCount'range) := axilR.tLastCount;
            when X"10" =>
               v.axilReadSlave.rdata(axilR.pauseCount'range) := axilR.pauseCount;
            when X"14" =>
               v.axilReadSlave.rdata(axilR.overflowCount'range) := axilR.overflowCount;
            when others => null;
         end case;
         -- Send Axi Response
         axiSlaveReadResponse(v.axilReadSlave);
      end if;

--      axiSlaveRegisterW(X"00", 0, v.countReset);
--      axiSlaveRegisterR(X"04", 0, fifoWrCount);
--      axiSlaveRegisterR(X"08", 0, axilR.fifoWrCountMax);
--      axiSlaveRegisterR(X"0C", 0, axilR.tLastCount);
--      axiSlaveRegisterR(X"10", 0, axilR.pauseCount);
--      axiSlaveRegisterR(X"14", 0, axilR.overflowCount);
--      axiSlaveDefault(AXI_RESP_OK_C);

      if (sAxisRst = '1') then
         v := AXIL_REG_INIT_C;
         v.axilWriteSlave := axilR.axilWriteSlave;
         v.axilReadSlave := axilR.axilReadSlave;
      end if;

      locAxilWriteSlave <= axilR.axilWriteSlave;
      locAxilReadSlave  <= axilR.axilReadSlave;

      axilRin <= v;

   end process axilComb;

   axilSeq : process (sAxisClk) is
   begin
      if (rising_edge(sAxisClk)) then
         axilR <= axilRin after TPD_G;
      end if;
   end process axilSeq;
end rtl;


