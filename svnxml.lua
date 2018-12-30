#!/usr/bin/lua
--============================================================
-- JJvB's micro XML-parser
-- slightly adapted for svn's --xml output
--============================================================

--
-- cache most used functions
--
local find=string.find
local push=table.insert

--
-- xml element metatable
--
local xml_mt={}
xml_mt.__index=xml_mt

function xml_mt:tag()
	return self[1]
end

function xml_mt:cdata()
	local cdata=self[2]
	if cdata and type(cdata)=="string" then return cdata end
	return nil,"no cdata in <"..self[1]..">"
end

function xml_mt:element(name)
	for i=2,#self do
		local obj=self[i]
		if obj[1]==name then
			return obj,i
		end
	end
	return nil,"no element <"..name.."> in <"..self[1]..">"
end

function xml_mt:elements()
	local n=1
	return function()
		n=n+1
		local elem=self[n]
		if elem then return elem,n end
	end
end

function xml_mt:attribute(name)
	local attr=self[name]
	if attr then return attr end
	return nil,"no attribute "..name.." in <"..self[1]..">"
end

--
-- substitute for %q
--
local st={['\n']='\\n',['\r']='\\r',['\t']='\\t',['\"']='\\"',['\\']='\\\\'}
local function vis(val,len)
	if type(val)~="string" then return tostring(val) end
	if len and #val>len then return vis(val:sub(1,len)).."..." end
	return '"'..(val:gsub("[\r\n\t\"\\]",st))..'"'
end

--
-- the XML parser
--
local function parsestr(str)
	local pos=1
	-- helper for parse error
	local function fail(msg)
		error(msg.." at "..vis(str:sub(pos),60),2)
	end
	-- helper to iterate over attributes
	local function namval()
		local a,b,nam,val=find(str,'^%s+([%w-]+)="([^"]+)"',pos)
		if a then pos=b+1 return nam,val end
	end
	local function need_obj()
		--
		-- begin tag
		--
		local a,b,tag=find(str,'^<([%w-]+)',pos)
		if not a then fail("expected '<tag'") end
		pos=b+1

		--
		-- attributes
		--
		local obj=setmetatable({tag},xml_mt)
		for nam,val in namval do obj[nam]=val end

		--
		-- quick end-of-tag
		--
		local a,b=find(str,'^/>%s*',pos)
		if a then
			pos=b+1
			return obj
		end

		--
		-- end-of tag
		--
		local a,b=find(str,'^>%s*',pos)
		if not a then fail("expected '>'") end
		pos=b+1

		--
		-- any elements?
		--
		while not find(str,"^</",pos) do
			if find(str,'^<',pos) then
				push(obj,need_obj())
			else
				local a,b,cdata=find(str,"^([^<>]+)%s*<",pos)
				if not a then fail("Expected literal") end
				pos=b+1-1 -- exclude '<'
				push(obj,cdata)
			end
		end

		--
		-- closing tag
		--
		local a,b,etag=find(str,'^</([%w-]+)>%s*',pos)
		if not a then fail("expected end-of-tag "..vis(tag)) end
		if etag~=tag then fail("tag mismatch "..vis(tag).." vs "..vis(etag))end
		pos=b+1
		return obj
	end

	--
	-- check for document prolog (ignored for svn)
	--
	local a,b,xmltag=find(str,"<(%?%w+)",pos)
	if a then
		pos=b+1
		xmlobj={xmltag}
		for nam,val in namval do xmlobj[nam]=val end
		local a,b=find(str,'^%?>%s*',pos)
		if not a then fail("expected '?>'") end
		pos=b+1
	end

	--
	-- get the one and only top object in xml
	--
	local obj=need_obj()
	
	--
	-- check
	--
	if pos<=#str then
		fail("expected no more data")
	end
	return obj
end

local svnxml={}
svnxml.parsestr=parsestr
return svnxml

