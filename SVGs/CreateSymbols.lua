#!/usr/bin/lua
--============================================================
-- this script converts *-symbols.svgs into separate .png
-- which can be used by wxWidges
--============================================================
--
-- it requires inkscape as executable in path
--

require"strict"
require"lfs"
lfs.chdir("SVGs") -- in case of run by ZBS in SVN package

--
-- my common shortcuts
--

local function printf(...)
	io.write(string.format(...))
	io.flush()
end

--
-- process one svg and export to PNGs
--

local function create_symbols(prefix)
	
	--
	-- step 1 : query for symbols related to the prefix
	--
	local symbols={}
	local cmd=string.format("inkscape --query-all %s-symbols.svg",prefix)
	local fd=assert(io.popen(cmd,"r"))
	for line in fd:lines() do
		local id,x,y,w,h=line:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
		if not id then error("bad line "..line) end
		if id:match(prefix.."%-%w+$") then
			local xx,yy=x-x%32,32*3-(y-y%32)
			print(id,x,y,w,h,xx,yy)
			symbols[#symbols+1]={id,xx,yy}
		end
	end
	fd:close()
	
	--
	-- step 2 : export selected symbols
	--
	for s=1,#symbols do
		local symbol,x,y=unpack(symbols[s])
		local png_path=string.format("../PNGs/%s.png",symbol)
		local cmd=string.format("inkscape -z %s-symbols.svg -export-id=%s --export-area=%d:%d:%d:%d --export-id-only -w 16 -h 16 -e \"%s\"",prefix,symbol,x,y,x+32,y+32,png_path)
		printf("cmd=[[%s]]\n",cmd)
		os.execute(cmd)
	end
end
create_symbols("status")
create_symbols("action")

