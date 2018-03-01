-------------------------------------------------------------------------------
-- Title      : PGP3 Transmit Protocol
-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2017-03-30
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
-- Takes pre-packetized AxiStream frames and creates a PGP3 66/64 protocol
-- stream (pre-scrambler). Inserts IDLE and SKP codes as needed. Inserts
-- user K codes on request.
-------------------------------------------------------------------------------
-- This file is part of SURF. It is subject to
-- the license terms in the LICENSE.txt file found in the top-level directory
-- of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of SURF, including this file, may be
-- copied, modified, propagated, or distributed except according to the terms
-- contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.AxiStreamPkg.all;
use work.AxiStreamPacketizer2Pkg.all;
use work.SsiPkg.all;
use work.Pgp3Pkg.all;

entity Pgp3TxProtocol is

   generic (
      TPD_G            : time                  := 1 ns;
      NUM_VC_G         : integer range 1 to 16 := 4;
      STARTUP_HOLD_G   : integer               := 1000;
      SKP_INTERVAL_G   : integer               := 5000;
      SKP_BURST_SIZE_G : integer               := 8);

   port (
      -- User Transmit interface
      pgpTxClk    : in  sl;
      pgpTxRst    : in  sl;
      pgpTxIn     : in  Pgp3TxInType;
      pgpTxOut    : out Pgp3TxOutType;
      pgpTxMaster : in  AxiStreamMasterType;
      pgpTxSlave  : out AxiStreamSlaveType;

      -- Status of local receive fifos
      -- These get synchronized by the Pgp3Tx parent
      locRxFifoCtrl  : in AxiStreamCtrlArray(NUM_VC_G-1 downto 0);
      locRxLinkReady : in sl;
      remRxLinkReady : in sl;

      -- Output Interface
      phyTxActive    : in  sl;
      protTxReady    : in  sl;
      protTxValid    : out sl;
      protTxStart    : out sl;
      protTxSequence : out slv(5 downto 0);
      protTxData     : out slv(63 downto 0);
      protTxHeader   : out slv(1 downto 0));

end entity Pgp3TxProtocol;

architecture rtl of Pgp3TxProtocol is

   type RegType is record
      skpCount       : slv(31 downto 0);
      startupCount   : integer;
      pgpTxSlave     : AxiStreamSlaveType;
      linkReady      : sl;
      frameTx        : sl;
      frameTxErr     : sl;
      protTxValid    : sl;
      protTxStart    : sl;
      protTxSequence : slv(5 downto 0);
      protTxData     : slv(63 downto 0);
      protTxHeader   : slv(1 downto 0);
   end record RegType;

   constant REG_INIT_C : RegType := (
      skpCount       => (others => '0'),
      startupCount   => 0,
      pgpTxSlave     => AXI_STREAM_SLAVE_INIT_C,
      linkReady      => '0',
      frameTx        => '0',
      frameTxErr     => '0',
      protTxValid    => '0',
      protTxStart    => '0',
      protTxSequence => (others => '0'),
      protTxData     => (others => '0'),
      protTxHeader   => (others => '0'));

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;

begin

   comb : process (locRxFifoCtrl, locRxLinkReady, pgpTxIn, pgpTxMaster, pgpTxRst, phyTxActive,
                   protTxReady, r, remRxLinkReady) is
      variable v        : RegType;
      variable linkInfo : slv(39 downto 0);
      variable dataEn   : sl;
   begin
      v := r;

      linkInfo := pgp3MakeLinkInfo(locRxFifoCtrl, locRxLinkReady);

      -- Always increment skpCount
      v.skpCount := r.skpCount + 1;

      -- Don't accept new frame data by default
      v.pgpTxSlave.tReady := '0';

      v.frameTx    := '0';
      v.frameTxErr := '0';

      v.protTxStart    := '0';
      v.protTxSequence := r.protTxSequence + 1;

      if (protTxReady = '1') then
         v.protTxValid := '0';
      end if;

      dataEn := ite(pgpTxIn.flowCntlDis = '1', r.linkReady, remRxLinkReady);

      if (v.protTxValid = '0' and phyTxActive = '1') then
         v.protTxValid := '1';

         -- Send only IDLE and SKP for STARTUP_HOLD_G cycles after reset
         v.startupCount := r.startupCount + 1;
         if (r.startupCount = 0) then
            v.protTxStart    := '1';
            v.protTxSequence := (others => '0');
         end if;
         if (r.startupCount = STARTUP_HOLD_G) then
            v.startupCount := r.startupCount;
            v.linkReady    := '1';
         end if;

         -- Decide whether to send IDLE, SKP, USER or data frames.
         -- Coded in reverse order of priority

         -- Send idle chars by default
         v.protTxData                        := (others => '0');
         v.protTxData(PGP3_LINKINFO_FIELD_C) := linkInfo;
         v.protTxData(PGP3_BTF_FIELD_C)      := PGP3_IDLE_C;
         v.protTxHeader                      := PGP3_K_HEADER_C;

         -- Send data if there is data to send
         if (pgpTxMaster.tValid = '1' and dataEn = '1') then
            v.pgpTxSlave.tReady := '1';  -- Accept the data

            if (ssiGetUserSof(PGP3_AXIS_CONFIG_C, pgpTxMaster) = '1') then
               -- SOF/SOC, format SOF/SOC char from data
               v.protTxData                        := (others => '0');
               v.protTxData(PGP3_BTF_FIELD_C)      := ite(pgpTxMaster.tData(PACKETIZER2_HDR_SOF_BIT_C) = '1', PGP3_SOF_C, PGP3_SOC_C);
               v.protTxData(PGP3_LINKINFO_FIELD_C) := linkInfo;
               v.protTxData(PGP3_SOFC_VC_FIELD_C)  := resize(pgpTxMaster.tData(PACKETIZER2_HDR_TDEST_FIELD_C), 4);  -- Virtual Channel
               v.protTxData(PGP3_SOFC_SEQ_FIELD_C) := resize(pgpTxMaster.tData(PACKETIZER2_HDR_SEQ_FIELD_C), 12);  -- Packet number
               v.protTxHeader                      := PGP3_K_HEADER_C;

            elsif (pgpTxMaster.tLast = '1') then
               -- EOF/EOC
               v.protTxData                               := (others => '0');
               v.protTxData(PGP3_BTF_FIELD_C)             := ite(pgpTxMaster.tData(PACKETIZER2_TAIL_EOF_BIT_C) = '1', PGP3_EOF_C, PGP3_EOC_C);
               v.protTxData(PGP3_EOFC_TUSER_FIELD_C)      := pgpTxMaster.tData(PACKETIZER2_TAIL_TUSER_FIELD_C);  -- TUSER LAST
               v.protTxData(PGP3_EOFC_BYTES_LAST_FIELD_C) := pgpTxMaster.tData(PACKETIZER2_TAIL_BYTES_FIELD_C);  -- Last byte count
               v.protTxData(PGP3_EOFC_CRC_FIELD_C)        := pgpTxMaster.tData(PACKETIZER2_TAIL_CRC_FIELD_C);  -- CRC
               v.protTxHeader                             := PGP3_K_HEADER_C;
               -- Debug output
               v.frameTx                                  := pgpTxMaster.tData(PACKETIZER2_TAIL_EOF_BIT_C);
               v.frameTxErr                               := v.frameTx and ssiGetUserEofe(PGP3_AXIS_CONFIG_C, pgpTxMaster);
            else
               -- Normal data
               v.protTxData(63 downto 0) := pgpTxMaster.tData(63 downto 0);
               v.protTxHeader            := PGP3_D_HEADER_C;
            end if;
         end if;

         -- 
         if (r.skpCount = pgpTxIn.skpInterval) then
            v.skpCount                     := (others => '0');
            v.pgpTxSlave.tReady            := '0';  -- Override any data acceptance.
            v.protTxData                   := (others => '0');
            v.protTxData(PGP3_BTF_FIELD_C) := PGP3_SKP_C;
            v.protTxHeader                 := PGP3_K_HEADER_C;
         end if;


         -- USER codes override data and delay SKP if they happen to coincide
         if (pgpTxIn.opCodeEn = '1' and dataEn = '1') then
            v.pgpTxSlave.tReady                      := '0';  -- Override any data acceptance.
            v.protTxData(PGP3_BTF_FIELD_C)           := PGP3_USER_C(conv_integer(pgpTxIn.opCodeNumber));
            v.protTxData(PGP3_USER_CHECKSUM_FIELD_C) := pgp3OpCodeChecksum(pgpTxIn.opCodeData);
            v.protTxData(PGP3_USER_OPCODE_FIELD_C)   := pgpTxIn.opCodeData;

            -- If skip was interrupted, hold it for next cycle
            if (r.skpCount = SKP_INTERVAL_G-1) then
               v.skpCount := r.skpCount;
            end if;
         end if;

         if (pgpTxIn.disable = '1') then
            v.linkReady    := '0';
            v.startupCount := 0;
            v.protTxData   := (others => '0');
            v.protTxHeader := (others => '0');
         end if;

      end if;
      
      -- Combinatorial outputs before the reset
      pgpTxSlave <= v.pgpTxSlave;

      if (pgpTxRst = '1') then
         v := REG_INIT_C;
      end if;

      rin <= v;

      protTxData     <= r.protTxData;
      protTxHeader   <= r.protTxHeader;
      protTxValid    <= r.protTxValid;
      protTxStart    <= r.protTxStart;
      protTxSequence <= r.protTxSequence;

      pgpTxOut.phyTxActive <= phyTxActive;
      pgpTxOut.linkReady   <= r.linkReady;
      pgpTxOut.frameTx     <= r.frameTx;
      pgpTxOut.frameTxErr  <= r.frameTxErr;

      for i in 15 downto 0 loop
         if (i < NUM_VC_G) then
            pgpTxOut.locOverflow(i) <= locRxFifoCtrl(i).overflow;
            pgpTxOut.locPause(i)    <= locRxFifoCtrl(i).pause;
         else
            pgpTxOut.locOverflow(i) <= '0';
            pgpTxOut.locPause(i)    <= '0';
         end if;
      end loop;


   end process comb;

   seq : process (pgpTxClk) is
   begin
      if (rising_edge(pgpTxClk)) then
         r <= rin after TPD_G;
      end if;
   end process seq;
end architecture rtl;