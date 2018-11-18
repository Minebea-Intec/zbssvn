#!/usr/bin/utils
--require"strict"


--
-- my common shortcuts
--
local sprintf=string.format
local sbyte=string.byte
local push=table.insert
local join=table.concat

local utils={}


local function printf(...)
	local ok,msg=pcall(sprintf,...)
	if not ok then error(msg,2) end
	io.write(msg)
	io.flush()
end
utils.printf=printf
--
-- my replacement for %q
--
local st=setmetatable({['\n']='\\n',['\r']='\\r',['\t']='\\t',['\"']='\\"',['\\']='\\\\'},
	{__index=function(t,k)local v=sprintf("\\%03d",sbyte(k)) t[k]=v return v end})

local function vis(val,len)
	if type(val)~="string" then return tostring(val) end
	if len and #val>len then return vis(val:sub(1,len)).."..." end
	return '"'..(val:gsub("[%z\001-\031\127-\255\\\"]",st))..'"'
end
utils.vis=vis

local function vist(val,sep)
	local did={}
	sep=","..(sep or "")
	local function vt(v)
		if type(v)~="table" then return vis(v) end
		if did[v] then return did[v] end
		did[v]=tostring(v)
		local r={}
		local d={}
		local kk=1
		local vv=v[kk]
		while vv do
			d[kk]=true
			push(r,vt(vv))
			kk=kk+1
			vv=v[kk]
		end
		for kk,vv in pairs(v) do
			if not d[kk] then
				if type(kk)=="string" and kk:match("^[_a-zA-Z][_a-zA-Z0-9]*$") then
					push(r,sprintf("%s=%s",kk,vt(vv)))
				else
					push(r,sprintf("[%s]=%s",vt(kk),vt(vv)))
				end
			end
		end
		return '{'..join(r,sep)..'}'
	end
	return vt(val)
end
utils.vist=vist

local function cmp(a,b)
	local ta,tb=type(a),type(b)
	if ta~=tb then return ta<tb end
	return a<b
end

--
-- like pairs, but sorted by keys
--
local function spairs(t,f)
	local ks={}
	for k in pairs(t) do
		ks[#ks+1]=k
	end
	table.sort(ks,f or cmp)
	local n=0
	return function()
		n=n+1
		local k=ks[n]
		if k then return k,t[k] end
	end
end
utils.spairs=spairs


--
-- (debug) visualisation of data structs
--
local function ShowData(nam,val,file)
	local out,fd=io.write,nil
	if file then
		fd=assert(io.open(file,"w"))
		out=function(...)fd:write(...)end
	end
	local have={}
	local function show_data(nam,val)
		if type(val)~="table" then
			out(nam,"=",vis(val),'\n')
			return
		end
		if have[val] then
			out(nam,"=",have[val],'\n')
			return
		end
		have[val]=nam
		for k,v in spairs(val) do
			if type(k)=="string" and k:match("^[_a-z]%w*$") then
				show_data(sprintf("%s.%s",nam,k),v)
			else
				show_data(sprintf("%s[%s]",nam,vis(k)),v)
			end
		end
	end
	show_data(nam,val)
	if fd then fd:close() end
end
utils.ShowData=ShowData

local function QW(text)
	local words={}
	for word in text:gmatch("%S+") do
		push(words,word)
		words[word]=true
	end
	return words
end
utils.QW=QW

local function save_file(file,...)
	local fd=assert(io.open(file,"wb"))
	fd:write(...)
	fd:close()
end
utils.save_file=save_file



return utils
