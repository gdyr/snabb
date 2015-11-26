#!/usr/bin/env luajit
io.stdout:setvbuf'no'
io.stderr:setvbuf'no'

--L2TP IP-over-IPv6 tunnelling program for testing.

local function assert(v, ...)
   if v then return v, ... end
   error(tostring((...)), 2)
end

local ffi    = require'ffi'
local S      = require'syscall'
local C      = ffi.C
local htons  = require'syscall.helpers'.htons

local DEBUG = os.getenv'DEBUG'

local function hex(s)
   return (s:gsub('(.)(.?)', function(c1, c2)
      return c2 and #c2 == 1 and
         string.format('%02x%02x ', c1:byte(), c2:byte()) or
         string.format('%02x ', c1:byte())
   end))
end

local digits = {}
for i=0,9 do digits[string.char(('0'):byte()+i)] = i end
for i=0,5 do digits[string.char(('a'):byte()+i)] = 10+i end
for i=0,5 do digits[string.char(('A'):byte()+i)] = 10+i end
local function parsehex(s)
   return (s:gsub('[%s%:%.]*(%x)(%x)[%s%:%.]*', function(hi, lo)
      local hi = digits[hi]
      local lo = digits[lo]
      return string.char(lo + hi * 16)
   end))
end

local function open_tap(name)
   local fd = assert(S.open('/dev/net/tun', 'rdwr, nonblock'))
   local ifr = S.t.ifreq{flags = 'tap, no_pi', name = name}
   assert(fd:ioctl('tunsetiff', ifr))
   return fd
end

local function open_raw(name)
   local fd = assert(S.socket('packet', 'raw, nonblock', htons(S.c.ETH_P.all)))
   local ifr = S.t.ifreq{name = name}
   assert(S.ioctl(fd, 'siocgifindex', ifr))
   assert(S.bind(fd, S.t.sockaddr_ll{
      ifindex = ifr.ivalue,
      protocol = 'all'}))
   return fd
end

local function can_read(timeout, ...)
   return assert(S.select({readfds = {...}}, timeout)).count > 0
end

local function can_write(timeout, ...)
   return assert(S.select({writefds = {...}}, timeout)).count > 0
end

local mtu = 1500
local buf = ffi.new('uint8_t[?]', mtu)
local function read(fd)
   local len = assert(S.read(fd, buf, mtu))
   return ffi.string(buf, len)
end

local function write(fd, s, len)
   assert(S.write(fd, s, len or #s))
end

local function close(fd)
   S.close(fd)
end

local tapname, ethname, smac, dmac, sip, dip, sid, did = ...
if not (tapname and ethname and smac and dmac and sip and dip and sid and did) then
   print('Usage: '..arg[0]..' TAP ETH SMAC DMAC SIP DIP SID DID')
   print'   TAP:  the tunneled interface: will be created if not present.'
   print'   ETH:  the tunneling interface: must have an IPv6 assigned.'
   print'   SMAC: the MAC address of ETH.'
   print'   DMAC: the MAC address of the gateway interface.'
   print'   SIP:  the IPv6 of ETH (long form).'
   print'   DIP:  the IPv6 of ETH at the other endpoint (long form).'
   print'   SID:  session ID (hex)'
   print'   DID:  peer session ID (hex)'
   os.exit(1)
end
smac = parsehex(smac)
dmac = parsehex(dmac)
sip  = parsehex(sip)
dip  = parsehex(dip)
sid  = parsehex(sid)
did  = parsehex(did)

local tap = open_tap(tapname)
local raw = open_raw(ethname)

print('tap  ', tapname)
print('raw  ', ethname)
print('smac ', hex(smac))
print('dmac ', hex(dmac))
print('sip  ', hex(sip))
print('dip  ', hex(dip))
print('sid  ', hex(sid))
print('did  ', hex(did))

local function decap_l2tp(s)
   local dmac = s:sub(1, 1+6-1)
   local smac = s:sub(1+6, 1+6+6-1)
   local eth_proto = s:sub(1+6+6, 1+6+6+2-1)
   if eth_proto ~= '\x86\xdd' then
      return nil, 'invalid eth_proto '..hex(eth_proto)
   end --not ipv6
   local ipv6_proto = s:sub(21, 21)
   if ipv6_proto ~= '\115' then
      return nil, 'invalid ipv6_proto '..hex(ipv6_proto)
   end --not l2tp
   local sip = s:sub(23, 23+16-1)
   local dip = s:sub(23+16, 23+16+16-1)
   local sid = s:sub(55, 55+4-1)
   local payload = s:sub(67)
   return smac, dmac, sip, dip, sid, payload
end

local function encap_l2tp(smac, dmac, sip, dip, did, payload)
   local cookie = '\0\0\0\0\0\0\0\0'
   local l2tp = did..cookie
   local len = #payload + #l2tp
   local len = string.char(bit.rshift(len, 8)) .. string.char(bit.band(len, 0xff))
   local ipv6_proto = '\115' --l2tp
   local maxhops = '\64'
   local ipv6 = '\x60\0\0\0'..len..ipv6_proto..maxhops..sip..dip
   local eth_proto = '\x86\xdd' --ipv6
   local eth = dmac..smac..eth_proto
   return eth..ipv6..l2tp..payload
end

while true do
   if can_read(1, tap, raw) then
		if can_read(0, raw) then
         local s = read(raw)
         local smac1, dmac1, sip1, dip1, did1, payload = decap_l2tp(s)
         local accept = smac1
            and smac1 == dmac
            and dmac1 == smac
            and dip1 == sip
            and sip1 == dip
            and did1 == sid
         if DEBUG then
				print('read   ', accept and 'accepted' or
					('rejected '..(smac1 and hex(dmac1) or dmac1)))
				if accept then
					print('  smac ', hex(smac1))
					print('  dmac ', hex(dmac1))
					print('  sip  ', hex(sip1))
					print('  dip  ', hex(dip1))
					print('  did  ', hex(did1))
					print('  #    ', #payload)
				end
			end
         if accept then
            write(tap, payload)
         end
      end
      if can_read(0, tap) then
         local payload = read(tap)
         local s = encap_l2tp(smac, dmac, sip, dip, did, payload)
         if DEBUG then
				print('write')
				print('  smac ', hex(smac))
				print('  dmac ', hex(dmac))
				print('  sip  ', hex(sip))
				print('  dip  ', hex(dip))
				print('  did  ', hex(did))
				print('  #    ', #payload)
			end
         write(raw, s)
      end
   end
end

tap:close()
raw:close()