-- intel1g: Device driver app for Intel 1G network cards
-- 
-- This is a device driver for Intel i210, i350 families of 1G network cards.
-- 
-- The driver aims to be fairly flexible about how it can be used. The
-- user can specify whether to initialize the NIC, which hardware TX
-- and RX queue should be used (or none), and the size of the TX/RX
-- descriptor rings. This should accomodate users who want to
-- initialize the NIC in an exotic way (e.g. with Linux igbe/ethtool),
-- or to dispatch packets across input queues in a specific way
-- (e.g. RSS and FlowDirector), or want to create many transmit-only
-- apps with private TX queues as a fast-path to get packets onto the
-- wire. The driver does not directly support these use cases but it
-- avoids abstractions that would potentially come into conflict with
-- them.
-- 
-- This flexibility does require more work from the user. For contrast
-- consider the intel10g driver: its VMDq mode automatically selects
-- available transmit/receive queues from a pool and initializes the
-- NIC to dispatch traffic to them based on MAC/VLAN. This is very
-- convenient but it also assumes that the NIC will only be used by
-- one driver in one process. This driver on the other hand does not
-- perform automatic queue assignment and so that must be done
-- separately (for example when constructing the app network with a
-- suitable configuration). The notion is that people constructing app
-- networks will have creative ideas that we are not able to
-- anticipate and so it is important to avoid assumptions about how
-- the driver will be used.
-- 
-- Data sheets (reference documentation):
-- http://www.intel.com/content/dam/www/public/us/en/documents/datasheets/ethernet-controller-i350-datasheet.pdf
-- http://www.intel.com/content/dam/www/public/us/en/documents/datasheets/i210-ethernet-controller-datasheet.pdf

-- run selftest() on APU2's second/middle NIC:
--  sudo SNABB_SELFTEST_INTEL1G_0="0000:02:00.0" ./snabb snsh -t apps.intel.intel1g

-- Note: rxqueue >0 not working yet!

module(..., package.seeall)

local ffi = require("ffi")
local C   = ffi.C
local pci = require("lib.hardware.pci")
local band, bor, bnot, lshift = bit.band, bit.bor, bit.bnot, bit.lshift
local lib  = require("core.lib")
local bits, bitset = lib.bits, lib.bitset
local compiler_barrier = lib.compiler_barrier
local tophysical = core.memory.virtual_to_physical

Intel1g = {}

function Intel1g:new(conf)
   local self = {}
   local pciaddress = conf.pciaddr
   local attach = conf.attach
   local txq = conf.txqueue or 0
   local rxq = conf.rxqueue or 0
   local ndesc = conf.ndescriptors or 512
   local rxburst = conf.rxburst or 128

   -- checks
   local deviceInfo= pci.device_info(pciaddress)
   assert(pci.is_usable(deviceInfo), "NIC is in use")
   assert(deviceInfo.driver == 'apps.intel.intel1g', "intel1g does not support this NIC")
   local ringSize= 1
   if deviceInfo.device == "0x1521" then		-- i350
    ringSize= 8
   elseif deviceInfo.device == "0x157b" then		-- i210
    ringSize= 4
   end
   assert((txq >=0) and (txq <ringSize), "txqueue must be in 0.." .. ringSize-1 .. " for " .. deviceInfo.model)
   assert((rxq >=0) and (rxq <ringSize), "rxqueue must be in 0.." .. ringSize-1 .. " for " .. deviceInfo.model)
   assert((ndesc %128) ==0, "ndesc must be a multiple of 128 (for Rx only)")	-- see 7.1.4.5

   -- Setup device access
   pci.unbind_device_from_linux(pciaddress)
   pci.set_bus_master(pciaddress, true)
   local regs, mmiofd = pci.map_pci_memory(pciaddress, 0)
   local r = {}

   -- Common utilities, see snabbswitch/src/lib/hardware/register.lua
   local function bitvalue (value)
      -- bitvalue(0x42)      => 0x42
      -- bitvalue({a=7,b=2}) => 0x42
      return (type(value) == 'table') and bits(value) or tonumber(value)
   end
   local function poke32 (offset, value)
      value = bitvalue(value)
      compiler_barrier()
      regs[offset/4] = value
   end
   local function peek32 (offset)
      compiler_barrier()
      return regs[offset/4]
   end
   local function set32 (offset, value)
      value = bitvalue(value)
      poke32(offset, bor(peek32(offset), value))
   end
   local function clear32 (offset, value)
      value = bitvalue(value)
      poke32(offset, band(peek32(offset), bnot(value)))
   end
   local function wait32 (offset, mask, value)
      -- Block until applying `bitmask` to the register value gives `value`.
      -- if `value` is not given then block until all bits in the mask are set.
      mask = bitvalue(mask)
      value = bitvalue(value)
      repeat until band(peek32(offset), mask) == (value or mask)
   end

   -- Return the next index into a ring buffer.
   -- (ndesc is a power of 2 and the ring wraps after ndesc-1.)
   local function ringnext (index)
      return band(index+1, ndesc-1)
   end

   local function yesno (value, bit)
    return bitset(value, bit) and 'yes' or 'no'
   end

   local function print_status(r, title)
    print(title)
    print(" MAC status")
     local macStatus= peek32(r.STATUS)
     print("  STATUS      = " .. bit.tohex(macStatus))
     print("  Full Duplex = " .. yesno(macStatus, 0))
     print("  Link Up     = " .. yesno(macStatus, 1))
     print("  PHYRA       = " .. yesno(macStatus, 10))
     local speed = (({10,100,1000,1000})[1+bit.band(bit.rshift(macStatus, 6),3)])
     print("  Speed       = " .. speed .. ' Mb/s')
    print(" Tx status")
     local tctl= peek32(r.TCTL)
     print("  TCTL        = " .. bit.tohex(tctl))
     print("  TXDCTL      = " .. bit.tohex(peek32(r.TXDCTL)))
     print("  TX Enable   = " .. yesno(tctl, 1))
    print(" Rx status")
     local rctl= peek32(r.RCTL)
     print("  RCTL        = " .. bit.tohex(rctl))
     print("  RXDCTL      = " .. bit.tohex(peek32(r.RXDCTL)))
     print("  RX Enable   = " .. yesno(rctl, 1))
     print("  RX Loopback = " .. yesno(rctl, 6))
    print(" PHY status")
     --[[
     local phyStatus= readPHY(0, 17)	-- 8.27.3.16 Copper Specific Status Reg 1 (page 0, register 17), p.556
     print("  STATUS      = " .. bit.tohex(phyStatus))
     print("  Full Duplex = " .. yesno(phyStatus, 13))
     print("  Copper Link = " .. yesno(phyStatus, 10))
     print("  Glabal Link = " .. yesno(phyStatus, 3))
     local speed = (({10,100,1000,1000})[1+bit.band(bit.rshift(phyStatus, 14),3)])
     print("  Speed       = " .. speed .. ' Mb/s')
     print("  MDI-X       = " .. yesno(phyStatus, 6))
     print("  Copper Sleep= " .. yesno(phyStatus, 4))	-- Copper Energy Detect Status
     ]]--
   end

   local counters= {rxPackets=0, rxBytes=0, txPackets=0, txBytes=0}

   local function print_stats(r)
    print("Stats from NIC registers:")
     print("  Rx Packets=        " .. peek32(r.TPR) .. "  Octets= " .. peek32(r.TORH) *2^32 +peek32(r.TORL))
     print("  Tx Packets=        " .. peek32(r.TPT) .. "  Octets= " .. peek32(r.TOTH) *2^32 +peek32(r.TOTL))
     print("  Rx Good Packets=   " .. peek32(r.GPRC))
     print("  Rx No Buffers=     " .. peek32(r.RNBC))
     print("  Rx Packets to Host=" .. peek32(r.RPTHC))
    print("Stats from counters:")
     print("  rxPackets=         " .. counters.rxPackets .. "  rxBytes= " .. counters.rxBytes)
     print("  txPackets=         " .. counters.txPackets .. "  txBytes= " .. counters.txBytes)
   end

   -- Shutdown functions
   local stop_nic, stop_transmit, stop_receive

   -- Device setup and initialization
   -- 8.1.3 Register Summary, p.359
   r.CTRL = 	0x00000		-- Device Control - RW
   --r.CTRL = 	0x00004		-- alias: Device Control - RW
   r.STATUS = 	0x00008		-- Device Status - RO
   r.CTRL_EXT =	0x00018		-- Extended Device Control - RW
   r.MDIC = 	0x00020		-- MDI Control - RW
   r.RCTL = 	0x00100		-- RX Control - RW
   r.TCTL = 	0x00400		-- TX Control - RW
   r.TCTL_EXT =	0x00404		-- Extended TX Control - RW
   r.MDICNFG = 	0x00E04		-- MDI Configuration - RW
   r.EEER = 	0x00E30		-- Energy Efficient Ethernet (EEE) Register
   r.EIMC = 	0x01528		-- 
   --r.RXDCTL =	0x02828		-- legacy alias: RX Descriptor Control queue 0 - RW
   --r.TXDCTL =	0x03828		-- legacy alias: TX Descriptor Control queue 0 - RW
   r.GPRC = 	0x04074		-- Good Packets Receive Count - R/clr
   r.RNBC = 	0x040A0		-- Receive No Buffers Count - R/clr
   r.TORL = 	0x040C0		-- Total Octets Received - R/clr
   r.TORH = 	0x040C4		-- Total Octets Received - R/clr
   r.TOTL = 	0x040C8		-- Total Octets Transmitted - R/clr
   r.TOTH = 	0x040CC		-- Total Octets Transmitted - R/clr
   r.TPR = 	0x040D0		-- Total Packets Received - R/clr
   r.TPT = 	0x040D4		-- Total Packets Transmitted - R/clr
   r.RPTHC = 	0x04104		-- Rx Packets to Host Count - R/clr
   r.MANC =	0x05820		-- 
   r.SWSM =	0x05b50		-- 
   r.SW_FW_SYNC=0x05b5c		-- Software Firmware Synchronization
   r.EEMNGCTL=	0x12030		-- Management EEPROM Control Register


   -- 3.7.4.4.4 Using PHY Registers, 
   local MDIOpage= -1		-- 8.27.3.21 HW resets to 0, but persists with SW reset!
   poke32(r.MDICNFG, 0)		-- 8.2.5 MDC/MDIO Config: 0x0000 = internal PHY

   local function writePHY(page, register, data)	-- 8.2.4 Media Dependent Interface Control
    if page ~= MDIOpage then
     MDIOpage= page
     writePHY(page, 22, (page %256))	-- select page by writing page to register 22 (from any page)
    end
    poke32(r.MDIC, 1 *2^26 + (register %2^5)*2^16  + (data %2^16))	-- OpCode 01b = MDI write
    wait32(r.MDIC, {Ready=28})
    assert(band(peek32(r.MDIC), bitvalue({Error=30})) ==0, "writePHY(): error")
   end

   local function readPHY(page, register)
    if page ~= MDIOpage then
     MDIOpage= page
     writePHY(page, 22, (page %256))	-- select page by writing page to register 22 (from any page)
    end
    poke32(r.MDIC, 2 *2^26 + (register %2^5)*2^16)	-- OpCode 10b = MDI read
    wait32(r.MDIC, {Ready=28})
    assert(band(peek32(r.MDIC), bitvalue({Error=30})) ==0, "readPHY(): error")
    return peek32(r.MDIC) %2^16
   end

   local function initPHY()
     -- 4.3.1.4 PHY Reset, p.131
     wait32(r.MANC, {BLK_Phy_Rst_On_IDE=18}, 0)	-- wait untill IDE link stable
print("initPHY: 1")
     -- 4.6.1 Acquiring Ownership over a Shared Resource, p.147
     -- see also 4.6.2 Releasing Ownership
     -- e.g. both software/software (SWSM.SMBI) & software/firmware (SWSM.SWESMBI) semamphores
     set32(r.SWSM, {SWESMBI= 1})		-- a. get software/firmware semaphore
     while band(peek32(r.SWSM), 0x02) ==0 do
       set32(r.SWSM, {SWESMBI= 1})
     end
print("initPHY: 2")
     wait32(r.SW_FW_SYNC, {SW_PHY_SM=1}, 0)	-- b. wait until firmware releases PHY
     set32(r.SW_FW_SYNC, {SW_PHY_SM=1})		-- set semaphore bit to own PHY
print("initPHY: 3")
     clear32(r.SWSM, {SWESMBI= 1})		-- c. release software/firmware semaphore
     set32(r.CTRL, {PHYreset= 31})		-- 3. set PHY reset
     C.usleep(1*100)				-- 4. wait 100 us
     clear32(r.CTRL, {PHYreset= 31})		-- 5. release PHY reset
print("initPHY: reset done")
     set32(r.SWSM, {SWESMBI= 1})		-- 6. release ownership
     while band(peek32(r.SWSM), 0x02) ==0 do
       set32(r.SWSM, {SWESMBI= 1})
     end
     clear32(r.SW_FW_SYNC, {SW_PHY_SM=1})	-- release PHY
     clear32(r.SWSM, {SWESMBI= 1})		-- release software/firmware semaphore
     wait32(r.EEMNGCTL, {CFG_DONE0=18})		-- 7. wait for CFG_DONE

     set32(r.SWSM, {SWESMBI= 1})		-- 8. a. get software/firmware semaphore
     while band(peek32(r.SWSM), 0x02) ==0 do
       set32(r.SWSM, {SWESMBI= 1})
     end
print("initPHY: 4")
     wait32(r.SW_FW_SYNC, {SW_PHY_SM=1}, 0)	-- b. wait until firmware releases PHY
     clear32(r.SWSM, {SWESMBI= 1})		-- c. release software/firmware semaphore
     --XXXXXXXXXXXXXXXXXXXXX			-- 9. configure PHY


     --XXXXXXXXXXXXXXXXXXXXX			-- 10. release ownership, see 4.6.2, p.148
     clear32(r.SW_FW_SYNC, {SW_PHY_SM=1})	-- release PHY
     clear32(r.SWSM, {SWESMBI= 1})		-- release software/firmware semaphore

print("initPHY: end")
   end

   --print_status(r, "Status before Init: ")
   --print_stats(r)
   if not attach then
      -- Initialize device
      poke32(r.EIMC, 0xffffffff)	-- disable interrupts
      poke32(r.CTRL, {RST = 26})	-- software / global reset, self clearing
      --poke32(r.CTRL, {DEV_RST = 29})	-- device reset (incl. DMA), self clearing
      C.usleep(4*1000)			-- wait at least 3 ms before reading, see 7.6.1.1
      wait32(r.CTRL, {RST = 26}, 0)	-- wait port reset complete
      --wait32(r.CTRL, {DEV_RST = 29}, 0)	-- wait device reset complete
      poke32(r.EIMC, 0xffffffff)	-- re-disable interrupts
      if conf.loopback == "MAC" then		-- 3.7.6.2.1 Setting the I210 to MAC Loopback Mode
         set32(r.CTRL, {SETLINKUP = 6})		-- Set CTRL.SLU (bit 6, should be set by default)
         set32(r.RCTL, {LOOPBACKMODE0 = 6})	-- Set RCTL.LBM to 01b (bits 7:6)
	 set32(r.CTRL, {FRCSPD=11, FRCDPLX=12})	-- Set CTRL.FRCSPD and FRCDPLX (bits 11 and 12)
	 set32(r.CTRL, {FD=0, SPEED1=9})	-- Set the CTRL.FD bit and program the CTRL.SPEED field to 10b (1 GbE)
	 set32(r.EEER, {EEE_FRC_AN=24})		-- Set EEER.EEE_FRC_AN to 1b to enable checking EEE operation in MAC loopback mode
         print("MAC Loopback set")
      elseif conf.loopback == "PHY" then	-- 3.7.6.3.1 Setting the I210 to Internal PHY Loopback Mode
         set32(r.CTRL, {SETLINKUP = 6})		-- Set CTRL.SLU (bit 6, should be set by default)
	 clear32(r.CTRL_EXT, {LinkMode1=23,LinkMode0=22})	-- set Link mode to internal PHY
         writePHY(0, 0, bitvalue({Duplex=8, SpeedMSB=6}))	-- PHYREG 8.27.3 Copper Control
         writePHY(2, 21, 0x06)					-- MAC interface speed 1GE
         --writePHY(0, 0, bitvalue({Duplex=8, SpeedMSB=6, CopperReset=15})) -- Copper Reset
         --writePHY(0, 0, bitvalue({Duplex=8, SpeedMSB=6, Loopback=14}))	-- Loopback
         writePHY(0, 0, bitvalue({Duplex=8, SpeedMSB=6, Loopback=14, CopperReset=15}))	-- Loopback & Reset
         print("PHY Loopback set")
      else				-- 3.7.4.4 Copper (Internal) PHY Link Config
					-- PHY tells MAC after auto-neg. (PCS and 802.3 clauses 28 (extensions) & 40 (.3ab)
					-- config generally determined by PHY auto-neg. (speed, duplex, flow control)
					-- PHY asserts link indication (LINK) to MAC
					-- SW driver must Set Link Up (CTRL.SLU) before MAC recognizes LINK from PHY and consider link up

         initPHY()				-- 4.5.7.2.1 Full Duplx, Speed auto neg. by PHY
         C.usleep(1000*1000)			-- wait for init to settle
         print("initPHY() done")
         clear32(r.STATUS, {PHYReset=10})	-- p.373
         --C.usleep(10*1000*1000)

         set32(r.CTRL, {SETLINKUP = 6})				-- Set CTRL.SLU (bit 6, should be set by default)
         clear32(r.CTRL_EXT, {LinkMode1=23,LinkMode0=22})	-- set Link mode to direct copper / internal PHY
         clear32(r.CTRL_EXT, {PowerDown=20})			-- disable power down
         set32(r.CTRL_EXT, {AutoSpeedDetect = 12})		-- p.373
         --set32(r.CTRL_EXT, {DriverLoaded = 28})		-- signal Device Driver Loaded

         --C.usleep(10*1000*1000)				-- wait for auto-neg.
         print("Waiting for link-up...")
         wait32(r.STATUS, {LinkUp=1})
         print("We have link-up!")

         print("MAC Status:")
         local status= peek32(r.STATUS)				-- p.372, 8.2.2
         print("  STATUS      = " .. bit.tohex(status))
         print("  Full Duplex = " .. yesno(status, 0))
         print("  Link Up     = " .. yesno(status, 1))
         print("  TxOFF Paused= " .. yesno(status, 4))
         local speed = (({10,100,1000,1000})[1+bit.band(bit.rshift(status, 6),3)])
         print("  Speed       = " .. speed .. ' Mb/s')
         local autoSpeed = (({10,100,1000,1000})[1+bit.band(bit.rshift(status, 8),3)])
         print("  Auto Speed  = " .. autoSpeed .. ' Mb/s')	-- Auto-Speed Detection Value (ASDV), result after setting CTRL_EXT.ASDCHK
         print("  PHY Reset   = " .. yesno(status, 10))
         print("  RxFlowCtrl  = " .. yesno(status, 27))		-- should be set by SW driver to auto-neg. from PHY
         print("  TxFlowCtrl  = " .. yesno(status, 28))		-- should be set by SW driver to auto-neg. from PHY

         print("PHY Status:")
         print("  PHYREG(0,0) = " .. bit.tohex(readPHY(0,0)) .. " Copper Control")	-- p.545, 
         print("  PHYREG(0,1) = " .. bit.tohex(readPHY(0,1)) .. " Copper Status")	-- p.546, 
         local phyID1= readPHY(0,2)
         print("  PHYREG(0,2) = " .. bit.tohex(phyID1) .. " PHY ID 1")		-- p.547, 8.27.3.3 PHY Identifier 1
	 assert(phyID1 == 0x0141, "PHY ID1 is not 0x0141")
         print("  PHYREG(0,4) = " .. bit.tohex(readPHY(0,4)) .. " Copper Auto-Neg Adv")	-- p.548, p.114, auto-neg. flow control (bits 10, 11)
         print("  PHYREG(0,5) = " .. bit.tohex(readPHY(0,5)) .. " Copper Link Partner Ability")	-- p.549, p.115, auto-neg. flow control (bits 10, 11) of partner
         print("  PHYREG(0,6) = " .. bit.tohex(readPHY(0,6)) .. " Copper Auto-Neg Expansion")  -- p.550
         print("  PHYREG(0,9) = " .. bit.tohex(readPHY(0,9)) .. " 1000BASE-T Control")  -- p.552
         print("  PHYREG(0,10) = " .. bit.tohex(readPHY(0,10)) .. " 1000BASE-T Status")  -- p.553
         print("  PHYREG(0,15) = " .. bit.tohex(readPHY(0,15)) .. " Extended Status")  -- p.554
         print("  PHYREG(0,16) = " .. bit.tohex(readPHY(0,16)) .. " Copper Specific Control 1")  -- p.554

	 local phyStatus= readPHY(0, 17)
         print("  PHYREG(0,17) = " .. bit.tohex(phyStatus) .. " Copper Specific Status 1")	-- p.556, 8.27.3.16
         local speed = (({10,100,1000,1000})[1+bit.band(bit.rshift(phyStatus, 14),3)])
         print("  Speed       = " .. speed .. ' Mb/s')
         print("  Full Duplex = " .. yesno(phyStatus, 13))
         print("  Page Rx     = " .. yesno(phyStatus, 12))
         print("  Spd Dplx Resolved = " .. yesno(phyStatus, 11))
         print("  Copper Link = " .. yesno(phyStatus, 10))
         print("  Tx Pause    = " .. yesno(phyStatus, 9))
         print("  Rx Pause    = " .. yesno(phyStatus, 8))
         print("  MDI-X       = " .. yesno(phyStatus, 6))
         print("  Downshift   = " .. yesno(phyStatus, 5))
         print("  Copper Sleep= " .. yesno(phyStatus, 4))	-- Copper Energy Detect Status
         print("  Glabal Link = " .. yesno(phyStatus, 3))
         print("  Polarity Rev= " .. yesno(phyStatus, 1))
         print("  Jabber      = " .. yesno(phyStatus, 0))

         print("  PHYREG(0,20) = " .. bit.tohex(readPHY(0,20)) .. " Copper Specific Control 2")  -- p.559
         print("  PHYREG(0,21)= " .. bit.tohex(readPHY(0,21)) .. " Copper Specific Rx Errors")	-- p.559
         print("  PHYREG(0,22)= " .. bit.tohex(readPHY(0,22)) .. " Page Addres")	-- p.559
         print("  PHYREG(0,23)= " .. bit.tohex(readPHY(0,23)) .. " Copper Specific Control 3")	-- p.560
         print("  PHYREG(2,16)= " .. bit.tohex(readPHY(2,16)) .. " MAC Specific Control 1")	-- p.561
         print("  PHYREG(2,19)= " .. bit.tohex(readPHY(2,19)) .. " MAC Specific Status")	-- p.561
         print("  PHYREG(2,21)= " .. bit.tohex(readPHY(2,21)) .. " MAC Specific Control 2")	-- p.563
         
      end
      
      -- Define shutdown function for the NIC itself
      stop_nic = function ()
         -- XXX Are these the right actions?
         clear32(r.CTRL, {SETLINKUP = 6})        -- take the link down
         pci.set_bus_master(pciaddress, false) -- disable DMA
      end
   end
   --print_status(r, "Status after Init: ")
   --print_stats(r)

   -- Transmit support
   if txq then
      -- Define registers for the transmit queue that we are using
      r.TDBAL  = 0xe000 + txq*0x40
      r.TDBAH  = 0xe004 + txq*0x40
      r.TDLEN  = 0xe008 + txq*0x40
      r.TDH    = 0xe010 + txq*0x40			-- Tx Descriptor Head - RO!
      r.TDT    = 0xe018 + txq*0x40			-- Tx Descriptor Head - RW
      r.TXDCTL = 0xe028 + txq*0x40
      r.TXCTL  = 0xe014 + txq*0x40

      -- Setup transmit descriptor memory
      local txdesc_t = ffi.typeof("struct { uint64_t address, flags; }")
      local txdesc_ring_t = ffi.typeof("$[$]", txdesc_t, ndesc)
      local txdesc = ffi.cast(ffi.typeof("$&", txdesc_ring_t),
                              memory.dma_alloc(ffi.sizeof(txdesc_ring_t)))

      -- Transmit state variables
      local txpackets = {}      -- packets currently queued
      local tdh, tdt = 0, 0     -- Cache of DMA head/tail indexes
      local txdesc_flags = bits({ifcs=25, dext=29, dtyp0=20, dtyp1=21, eop=24})

      -- Initialize transmit queue
      poke32(r.TDBAL, tophysical(txdesc) % 2^32)
      poke32(r.TDBAH, tophysical(txdesc) / 2^32)
      poke32(r.TDLEN, ndesc * ffi.sizeof(txdesc_t))
      set32(r.TCTL, 2)
      poke32(r.TXDCTL, {WTHRESH=16, ENABLE=25})
      poke32(r.EIMC, 0xffffffff)      -- re-disable interrupts

      --print_status(r, "Status after init transmit: ")

      -- Return true if we can enqueue another packet for transmission.
      local function can_transmit ()
         return ringnext(tdt) ~= tdh
      end

      -- Queue a packet for transmission.
      -- Precondition: can_transmit() => true
      local function transmit (p)
         txdesc[tdt].address = tophysical(p.data)
         txdesc[tdt].flags = bor(p.length, txdesc_flags, lshift(p.length+0ULL, 46))
         txpackets[tdt] = p
         tdt = ringnext(tdt)
	 counters.txPackets= counters.txPackets +1
	 counters.txBytes= counters.txBytes +p.length
      end

      -- Synchronize DMA ring state with hardware.
      -- Free packets that have been transmitted.
      local function sync_transmit ()
         local cursor = tdh
         tdh = peek32(r.TDH)			-- possible race condition, see 7.1.4.4, 7.2.3 
         while cursor ~= tdh do
            if txpackets[cursor] then
               packet.free(txpackets[cursor])
               txpackets[cursor] = nil
            end
            cursor = ringnext(cursor)
         end
         poke32(r.TDT, tdt)
      end

      -- Define push() method for app instance.
      function self:push ()
         local li = self.input[1]
         assert(li, "intel1g: no input link")
         while not link.empty(li) and can_transmit() do
            transmit(link.receive(li))
         end
         sync_transmit()
      end

      -- Define shutdown function for transmit
      stop_transmit = function ()
         poke32(r.TXDCTL, 0)
         wait32(r.TXDCTL, {ENABLE=25}, 0)
         for i = 0, ndesc-1 do
            if txpackets[i] then
               packet.free(txpackets[i])
               txpackets[i] = nil
            end
         end
      end
   end

   -- Receive support
   if rxq then
      r.RDBAL  = 0xc000 + rxq*0x40
      r.RDBAH  = 0xc004 + rxq*0x40
      r.RDLEN  = 0xc008 + rxq*0x40
      r.SRRCTL = 0xc00c + rxq*0x40	-- Split and Replication Receive Control
      r.RDH    = 0xc010 + rxq*0x40	-- Rx Descriptor Head - RO
      r.RXCTL  = 0xc014 + rxq*0x40	-- Rx DCA Control Registers
      r.RDT    = 0xc018 + rxq*0x40	-- Rx Descriptor Tail - RW
      r.RXDCTL = 0xc028 + rxq*0x40	-- Receive Descriptor Control

      local rxdesc_t = ffi.typeof([[
        struct { 
          uint64_t address;
          uint16_t length, cksum;
          uint8_t status, errors;
          uint16_t vlan;
        } __attribute__((packed))
      ]])
      assert(ffi.sizeof(rxdesc_t), "sizeof(rxdesc_t)= ".. ffi.sizeof(rxdesc_t) .. ", but must be 16 Byte")
      local rxdesc_ring_t = ffi.typeof("$[$]", rxdesc_t, ndesc)
      local rxdesc = ffi.cast(ffi.typeof("$&", rxdesc_ring_t),
                              memory.dma_alloc(ffi.sizeof(rxdesc_ring_t)))
      
      -- Receive state
      local rxpackets = {}
      local rdh, rdt= 0, 0

      -- Initialize receive queue
      -- see em_initialize_receive_unit() in http://cvsweb.openbsd.org/cgi-bin/cvsweb/src/sys/dev/pci/if_em.c
      clear32(r.RCTL, {rxen = 1})	-- disable receiver while setting up descriptor ring
      --poke32(r.RDTR, )		-- set Receive Delay Timer Register (only for interrupt ops?)
      poke32(r.RDBAL, tophysical(rxdesc) % 2^32)
      poke32(r.RDBAH, tophysical(rxdesc) / 2^32)
      poke32(r.RDLEN, ndesc * ffi.sizeof(rxdesc_t))

      for i = 0, ndesc-1 do
	local p= packet.allocate()
	rxpackets[i]= p
        rxdesc[i].address= tophysical(p.data)
        rxdesc[i].status= 0
      end

      local rctl= {}
      rctl.RXEN= 1			-- enable receiver
      rctl.SBP= 2			-- store bad packet
      rctl.RCTL_UPE= 3			-- unicast promiscuous enable
      rctl.RCTL_MPE= 4			-- multicast promiscuous enable
      rctl.LPE= 5			-- Long Packet Enable
-- deadly!      rctl.LBM_MAC= 6			-- MAC loopback mode
      rctl.BAM= 15			-- broadcast enable
      --rctl.SZ_512= 17			-- buffer size: use SRRCTL for larger buffer sizes
      --rctl.RCTL_RDMTS_HALF=		-- rx desc min threshold size
      rctl.SECRC= 26			-- i350 has a bug where it always strips the CRC, so strip CRC and cope in rxeof

      poke32(r.SRRCTL, 10)		-- buffer size in 1 KB increments
      set32(r.SRRCTL, {Drop_En= 31})	-- drop packets when no descriptors available
      set32(r.RXDCTL, {ENABLE= 25})	-- enable the RX queue
      wait32(r.RXDCTL, {ENABLE=25})	-- wait until enabled

      poke32(r.RCTL, rctl)		-- enable receiver

      --poke32(r.RDH, 0)		-- Rx descriptor Head (RO)
      --poke32(r.RDT, 0)		-- Rx descriptor Tail
      poke32(r.RDT, ndesc-1)		-- Rx descriptor Tail, trigger NIC to cache descriptors

      --print_status(r, "Status after init receive: ")

      -- Return true if there is a DMA-completed packet ready to be received.
      local function can_receive ()
         local r= (rdt ~= rdh) and (band(rxdesc[rdt].status, 0x01) ~= 0)
	 --print("can_receive():  r=",r, "  rdh=",rdh, "  rdt=",rdt)
         return r
      end

      local lostSeq, lastSeqNo = 0, -1

      -- Receive a packet
      local function receive ()
         assert(can_receive())		-- precondition
         local desc = rxdesc[rdt]
         local p = rxpackets[rdt]
         p.length = desc.length
	 counters.rxPackets= counters.rxPackets +1
	 counters.rxBytes= counters.rxBytes +p.length
         local np= packet.allocate()	-- get empty packet buffer
         rxpackets[rdt] = np		-- disconnect received packet, connect new buffer
         rxdesc[rdt].address= tophysical(np.data)
	 rxdesc[rdt].status= 0		-- see 7.1.4.5: zero status before bumping tail pointer
         rdt = ringnext(rdt)
         --print("receive(): p.length= ", p.length)
         rxSeqNo= p.data[3] *2^24 + p.data[2] *2^16 + p.data[1] *2^8 + p.data[0]
         --print("receive(): txFrame= ", rxSeqNo)
         lastSeqNo= lastSeqNo +1
         while lastSeqNo < rxSeqNo do
          --print("receive(): lastSeqNo , rxSeqNo= ", lastSeqNo, rxSeqNo)
	  --print("receive(): missing ", lastSeqNo)
          lostSeq= lostSeq +1
          lastSeqNo= lastSeqNo +1
         end
         return p
      end

      -- Synchronize receive registers with hardware.
      local function sync_receive ()
         rdh = peek32(r.RDH)				-- possible race condition, see 7.1.4.4, 7.2.3
         --rdh = band(peek32(r.RDH), ndesc-1)		-- from intel1g: Luke observed (RDH == ndesc) !?
         --rdh = math.min(peek32(r.RDH), ndesc-1)	-- from intel10g
         assert(rdh <ndesc)				-- from intel1g: Luke observed (RDH == ndesc) !?
         --C.full_memory_barrier()			-- from intel10g, why???
         poke32(r.RDT, rdt)
	 --print("sync_receive():  rdh=",rdh, "  rdt=",rdt)
      end
      
      -- Define pull() method for app instance.
      function self:pull ()
         local lo = self.output[1]
         assert(lo, "intel1g: no output link")
         local limit = rxburst
         while limit > 0 and can_receive() do
            link.transmit(lo, receive())
            limit = limit - 1
         end
         sync_receive()
      end

      -- stop receiver, see 4.5.9.2
      stop_receive = function ()
         --poke32(r.RXDCTL, 0)
         clear32(r.RXDCTL, {ENABLE=25})
         wait32(r.RXDCTL, {ENABLE=25}, 0)
         for i = 0, ndesc-1 do
            if rxpackets[i] then
               packet.free(rxpackets[i])
               rxpackets[i] = nil
            end
         end
         -- XXX return dma memory of Rx descriptor ring
	print("stop_receive(): lostSeq ", lostSeq)
      end
   end

   -- Stop all functions that are running.
   function self:stop ()
      if stop_receive  then stop_receive()  end
      if stop_transmit then stop_transmit() end
      if stop_nic      then stop_nic()      end
      print_status(r, "Status after Stop: ")
      print_stats(r)

      print(" PHY status")
      local phyStatus= readPHY(0, 17)	-- 8.27.3.16 Copper Specific Status Reg 1 (page 0, register 17), p.556
       print("  STATUS      = " .. bit.tohex(phyStatus))
       print("  Full Duplex = " .. yesno(phyStatus, 13))
       print("  Copper Link = " .. yesno(phyStatus, 10))
       print("  Glabal Link = " .. yesno(phyStatus, 3))
       local speed = (({10,100,1000,1000})[1+bit.band(bit.rshift(phyStatus, 14),3)])
       print("  Speed       = " .. speed .. ' Mb/s')
       print("  MDI-X       = " .. yesno(phyStatus, 6))
       print("  Copper Sleep= " .. yesno(phyStatus, 4))	-- Copper Energy Detect Status
   end

   return self
   --return setmetatable(self, {__index = Intel1g})
end

function selftest ()
   print("selftest: Intel1g")
   local pciaddr = os.getenv("SNABB_SELFTEST_INTEL1G_0")
   if not pciaddr then
      print("SNABB_SELFTEST_INTEL1G_0 not set")
      os.exit(engine.test_skipped_code)
   end
   
   local c = config.new()
   local basic = require("apps.basic.basic_apps")
   config.app(c, "source", basic.Source)
   config.app(c, "sink", basic.Sink)
   -- try MAC loopback with i210 or i350 NIC
    config.app(c, "nic", Intel1g, {pciaddr=pciaddr, loopback=true})
    --config.app(c, "nic", Intel1g, {pciaddr=pciaddr, loopback=true, rxburst=512})
    --config.app(c, "nic", Intel1g, {pciaddr=pciaddr, loopback="MAC", rxburst=512})
    --config.app(c, "nic", Intel1g, {pciaddr=pciaddr, loopback="PHY", rxburst=512})
    --config.app(c, "nic", Intel1g, {pciaddr=pciaddr, loopback=true, txqueue=1})
    --config.app(c, "nic", Intel1g, {pciaddr=pciaddr, loopback=true, txqueue=1, rxqueue=1})
    config.link(c, "source.tx -> nic.rx")
    config.link(c, "nic.tx -> sink.rx")
   -- replace intel1g by Repeater
    --config.app(c, "repeater", basic.Repeater)
    --config.link(c, "source.tx -> repeater.input")
    --config.link(c, "repeater.output -> sink.rx")
   engine.configure(c)

   -- showlinks: src/core/app.lua calls report_links()
   engine.main({duration = 10, report = {showapps = true, showlinks = true, showload= true}})
   print("selftest: ok")

   engine.app_table.nic.stop()

   --local li = engine.app_table.nic.input[1]
   local li = engine.app_table.nic.input["rx"]		-- same-same as [1]
   assert(li, "Intel1g: no input link")
   local s= link.stats(li)
   print("input link:  txpackets= ", s.txpackets, "  rxpackets= ", s.rxpackets, "  txdrop= ", s.txdrop)

   --local lo = engine.app_table.nic.output[1]
   local lo = engine.app_table.nic.output["tx"]		-- same-same as [1]
   assert(lo, "Intel1g: no output link")
   local s= link.stats(lo)
   print("output link: txpackets= ", s.txpackets, "  rxpackets= ", s.rxpackets, "  txdrop= ", s.txdrop)
end
