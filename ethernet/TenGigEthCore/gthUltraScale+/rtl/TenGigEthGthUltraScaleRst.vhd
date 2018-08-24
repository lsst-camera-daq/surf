-------------------------------------------------------------------------------
-- File       : TenGigEthGthUltraScaleRst.vhd
-- Company    : SLAC National Accelerator Laboratory
-- Created    : 2018-04-06
-- Last update: 2018-04-09
-------------------------------------------------------------------------------
-- Description: 10GBASE-R Ethernet Reset Module
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the 
-- top-level directory of this distribution and at: 
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html. 
-- No part of 'SLAC Firmware Standard Library', including this file, 
-- may be copied, modified, propagated, or distributed except according to 
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;

library unisim;
use unisim.vcomponents.all;

entity TenGigEthGthUltraScaleRst is
   generic (
      TPD_G : time := 1 ns);
   port (
      coreClk   : in  sl;
      coreRst   : in  sl;
      txGtClk   : in  sl;
      txRstdone : in  sl;
      rxRstdone : in  sl;
      phyClk    : out sl;
      phyRst    : out sl;
      phyReady  : out sl);
end TenGigEthGthUltraScaleRst;

architecture rtl of TenGigEthGthUltraScaleRst is

   signal phyClock : sl;
   signal ready    : sl;

begin

   phyClk   <= phyClock;
   phyClock <= txGtClk;

   U_RstSync : entity work.RstSync
      generic map (
         TPD_G => TPD_G)
      port map (
         clk      => phyClock,
         asyncRst => coreRst,
         syncRst  => phyRst);

   ready <= txRstdone and rxRstdone;

   U_Sync : entity work.Synchronizer
      generic map (
         TPD_G => TPD_G)
      port map (
         clk     => phyClock,
         dataIn  => ready,
         dataout => phyReady);

end rtl;
