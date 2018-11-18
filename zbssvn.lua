local SVN_PLUGIN =
{
	name = "SVN plugin",
	description = "Plugin to use svn functionality out of zbs",
	author = "Klemens Mentel, J.Jørgen von Bargen",
}

--------------------------------------------------
-- common shortcuts
--------------------------------------------------
local sprintf=string.format
local push=table.insert
local join=table.concat

--
-- helper mt to autocreate entries in table
--
local mt_autocreate={}
mt_autocreate.__index=function(t,k) local v=setmetatable({},mt_autocreate) rawset(t,k,v) return v end

--------------------------------------------------
-- common utility/debug functions
--------------------------------------------------
local function gettime()
	return wx.wxGetLocalTimeMillis():ToDouble()*0.001
end

local function quote(value)
	if type(value)=="table" then
		local q={}
		for k,v in pairs(value) do
			q[k]='"'..tostring(v)..'"'
		end
		return join(q,' ')
	else
		return '"'..tostring(value)..'"'
	end
end

local function d2u(path)
	return path:gsub("\\","/"):gsub("/$","")
end
-----------------------------------------------------
-- read config values
-----------------------------------------------------
local config_svn=ide.config.svn or {}
local verbose=config_svn.verbose or 0			-- 0 only errors
local savetemp=config_svn.savetemp or false
local path_to_diff_tool = config_svn.diff -- or 'meld'

local TEMP=d2u(config_svn.tmp or os.getenv("TEMP") or os.getenv("TMP") or "/tmp")

-----------------------------------------------------
-- load submodules without clobbering global packages
-- cannot use require else ZBS will get confused
-----------------------------------------------------

local source=debug.getinfo(1,"S").source:gsub("^@","")
-- {
--	linedefined=0,
--  lastlinedefined=1088,
--  source="@/home/user/.zbstudio/packages/SVN/svn.lua",
--  what="main",
--  short_src="/home/user/.zbstudio/packages/SVN/svn.lua"
-- }
local sourcedir=source:gsub("\\","/"):gsub("(.*)/.*","%1"):gsub("^~",os.getenv("HOME") or ".")
io.write(">"..sourcedir.."<\n")io.flush()
local svnxml=dofile(sourcedir.."/svnxml.lua")
local utils=dofile(sourcedir.."/utils.lua")

local zbs_svn_plugin_id = ID("svn.zbs_svn_plugin")

-- configuration
-- SET in user.lua to path.diff = [[C:\\Program Files\\ExamDiff Pro\\ExamDiff.exe]]

--path_to_diff_tool='"C:\\Program Files\\TortoiseSVN\\bin\\TortoiseUDiff.exe"'


-- consts..
-- calculate unique IDs
local ID_REFRESH = ID("svn.action.refresh")
local ID_UPDATE  = ID("svn.action.update")
local ID_COMMIT  = ID("svn.action.commit")
local ID_REVERT  = ID("svn.action.revert")
local ID_ADD     = ID("svn.action.add")
local ID_DELETE  = ID("svn.action.delete")
local ID_RESOLVE = ID("svn.action.resolve")
local ID_DIFF    = ID("svn.action.diff")
local ID_IGNORE  = ID("svn.action.ignore")

local ID_CHECKLISTBOX      = ID("svn.checklistbox")
local ID_COMBOBOX          = ID("svn.combobox")
local ID_TEXTCTRL          = ID("svn.textctrl")
local ID_DIFFCTRL          = ID("svn.diffctrl")

local ID_LISTCONTROL=ID("svn.listctrl")

local TMP=os.getenv("TEMP")or os.getenv("TMP") or "/tmp"
--============================================================
-- utility functions for debug, functional not needed
--============================================================

local vis=utils.vis
local QW=utils.QW
local vist=utils.vist
local spairs=utils.spairs
local printf=utils.printf
local save_file=utils.save_file



--
-- prepare for internal diff view
--
local fontCourier=wx.wxFont(9,wx.wxFONTFAMILY_MODERN,wx.wxFONTSTYLE_NORMAL,wx.wxFONTWEIGHT_NORMAL,
	false,"Courier New",wx.wxFONTENCODING_DEFAULT)
wx.wxDARK_GREEN=wx.wxColour(0,128,0);
wx.wxDARK_RED=wx.wxColour(128,0,0);

------------------------------------------------------------
-- the OneAndOnly command execute to capture output
------------------------------------------------------------
function SVN_PLUGIN:do_command(cmd,showoutput)
	self.SetStatus("Execute %.80s",cmd)
	if verbose>=1 then
		printf("SVN_PLUGIN:execute[[%s]]\n",cmd) 
	end
	local t0=gettime()
	wx.wxBeginBusyCursor()
	wx.wxSetEnv("LANG","C") -- wxExecuteStdoutStderr does not like utf8 output :-/
	local sts,output,errors=wx.wxExecuteStdoutStderr(cmd)
	wx.wxEndBusyCursor()
	local t1=gettime()
	output=join(output,"\n"):gsub("%s+$","")
	errors=join(errors,"\n"):gsub("%s+$","")	
	if showoutput then
		if output~="" then DisplayOutputLn(output) end
		if errors~="" then DisplayOutputLn(errors) end
	end
	if sts~=0 then
		local msg=sprintf("Execution of\n%s\nfailed!\nOutput=%s\nErrors=%s\n",cmd,output,errors)
		wx.wxMessageBox(msg,"Subversion",wx.wxOK+wx.wxCANCEL+wx.wxICON_ERROR)
	end
	if verbose>=1 then
		printf("SVN_PLUGIN:sts=%s in %.3f sec\n",vis(sts),t1-t0)
		printf("SVN_PLUGIN:output=%s\n",vis(output,80))
		printf("SVN_PLUGIN:errors=%s\n",vis(errors,80))
	end
	self.SetStatus("Did %.80s",cmd)
	return output..errors,sts
end



function SVN_PLUGIN:get_svn_xml(action,args)
	local cmd="svn "..action.." "..args
	SVN_PLUGIN:SetStatus("execute %s",cmd)
	local output,sts=self:do_command(cmd)
	if sts~=0 then
		SVN_PLUGIN:SetStatus("failed %s",cmd)
		return nil
	end
	if savetemp then
		save_file(TEMP.."/svn-"..action..".xml",output)
	end
	SVN_PLUGIN:SetStatus("parse %s",cmd)
	local xml=svnxml.parsestr(output) or Error("no xml in \n",action)
	if xml:tag()~=action then
		Error("expected <%s> have <%s>\n",action,xml:tag())
	end
	SVN_PLUGIN:SetStatus("svn "..action.." done")
	return xml
end


function SVN_PLUGIN:GetSvnLog()
	local comments=self.SvnLogComments
	if comments==nil then
		wx.wxBeginBusyCursor()
		local svnlog=self:get_svn_xml("log","--xml --limit 20 "..quote(self.WorkingDir))
		wx.wxEndBusyCursor()
		comments={}
		for logentry in svnlog:elements() do
			local msg=(logentry:element"msg":cdata() or ""):gsub("%s+$","")
			if msg~="" then
				push(comments,msg)
			end
		end
		self.SvnLogComments=comments
	end
	return comments
end

function SVN_PLUGIN:FixPath(filename)
	local fn=wx.wxFileName(filename)
	fn:Normalize(wx.wxPATH_NORM_ALL,self.WorkingDir)
	return fn:GetFullPath()
end

--============================================================
-- Status data
-- name    = name of status in xml (== name of status png)
-- allowed = list of allowed actions on this status
-- show    = initial state of show control
--============================================================
local SVN_STATUS=
{
	{name="normal",		allowed=QW"update delete",show=false},
	{name="modified",	allowed=QW"update commit revert diff"},
	{name="conflicted",	allowed=QW"update revert resolve diff"},
	{name="added",		allowed=QW"commit revert diff"},
	{name="deleted",	allowed=QW"commit revert"},
	{name="incomplete",	allowed=QW"update"},
	{name="unversioned",allowed=QW"add delete ignore"},
	{name="obstructed",	},
	{name="missing",	allowed=QW"update"},
	{name="none",		},
	{name="external",	allowed=QW"update"	,show=false },
	{name="ignored",	allowed=QW"delete"	,show=false },
}
-- make the hash tables by name
for i,s in ipairs(SVN_STATUS) do SVN_STATUS[s.name]=s end


local SVN_ACTION=
{
	{name="refresh",enable=true}, -- this is always enabled
	{name="update",enable=true}, -- this is always enabled
	{name="info",enable=true}, -- this is always enabled
	{}, -- separator
	{name="commit"},
	{name="revert"},
	{name="resolve"},
	{}, -- separator
	{name="add"},
	{name="delete"},
	{name="ignore"},
	{}, -- separator
	{name="diff"},
}
for i,action in ipairs(SVN_ACTION) do if action.name then SVN_ACTION[action.name]=action end end


--============================================================
-- image handling
--============================================================

local function is_file(file)
	if wx.wxFileName(file):FileExists() then return file end
end

--
-- Get possible icon from .zbstudio/packages/SVN/PNGs
--
local imgSize = wx.wxSize(16,16)
local function my_getBitmap(name)
	--printf("my_getBitmap(%s)\n",name)
	local png_file=is_file(sourcedir:gsub("\\","/").."/PNGs/"..name..".png")
	if png_file then
		-- DisplayOutputLn("PNG_FILE=",png_file)
		return wx.wxBitmap(png_file)
	end
	printf("svn: no .png for %q\n",name)
	return wx.wxArtProvider.GetBitmap(name,"OTHER",imgSize)
end

local function CreateImageList(prefix)
	--
	-- create the image list
	--
	local img_w,img_h=imgSize:GetWidth(),imgSize:GetHeight()
	--DisplayOutputLn("img_w=",img_w,"img_h=",img_h)
	local imageList = wx.wxImageList(img_w,img_h);
	for i,data in ipairs(SVN_STATUS) do
		local bmp=my_getBitmap(prefix.."-"..data.name)
		data.bmpId=imageList:Add(bmp) -- 1 = add
		bmp:delete()
	end
	return imageList
end

function SVN_PLUGIN:SetStatus(...)
	ide:SetStatus(sprintf(...))
end




function SVN_PLUGIN:CreateMenuFor(enables)

	local menu = wx.wxMenu {
		--{ ID_REFRESH,TR("Refresh") },
		{ ID_UPDATE,TR("Update") },
		{ },-- separator
		{ ID_COMMIT,TR("Commit") },
		{ ID_REVERT,TR("Revert") },
		{ },-- separator
		{ ID_RESOLVE,TR("Resolve") },
		{ },-- separator
		{ ID_ADD,TR("Add") },
		{ ID_DELETE,TR("Delete") },
		{ ID_IGNORE,TR("Ignore") },
		{ },-- separator
		{ ID_DIFF,TR("SVN Diff") },
	}

	-- enable menu entry according to svn state
	menu:Enable(ID_COMMIT,enables.commit ==true)
	menu:Enable(ID_REVERT,enables.revert ==true)
	menu:Enable(ID_RESOLVE,enables.resolve==true)
	menu:Enable(ID_ADD,enables.add    ==true)
	menu:Enable(ID_DELETE,enables.delete ==true)
	menu:Enable(ID_DIFF,enables.diff   ==true)
	menu:Enable(ID_IGNORE,enables.ignore ==true)
	return menu
end

--
-- render output of diff to a text control
--
local function DiffOutputToTextCtrl(ctrl,output)
	ctrl:Clear()
	local block,have_color
	for line in output:gmatch("[^\r\n]+") do
		local want_color=wx.wxBLACK
		if line:match("^%+") then
			want_color=wx.wxDARK_GREEN
		elseif line:match("^%-") then
			want_color=wx.wxDARK_RED
		end
		if have_color~=want_color then
			if block then 
				ctrl:AppendText(block)
				block=nil
			end
			ctrl:SetDefaultStyle(wx.wxTextAttr(want_color))
			have_color=want_color
		end
		block=(block or "")..line.."\n"
	end
	if block then 
		ctrl:AppendText(block)
	end
end


function SVN_PLUGIN:CreateDialog(Caption,action,FileList,comment_needed,diffallowed)
	printf("SVN_PLUGIN:CreateDialog(%s,%s,%s,%s,%s)\n",vis(Caption),vis(action),vist(FileList),vis(comment_needed),vis(diffallowed))
	if type(FileList)=="string" then FileList={FileList}end
	if #FileList==0 then return end

	local frame = self.parent
	--
	-- the dialog with a sizer
	--
	local dialog = wx.wxDialog(frame,wx.wxID_ANY,Caption,
		wx.wxDefaultPosition,wx.wxDefaultSize,
		wx.wxDEFAULT_DIALOG_STYLE+wx.wxRESIZE_BORDER)
	local mainSizer = wx.wxBoxSizer(wx.wxVERTICAL)

	--
	-- the text input area
	--
	local textCtrl,comboBox

	if comment_needed then  -- some actions do not need a comment e.g. resolve/revert

		textCtrl = wx.wxTextCtrl(dialog,ID_TEXTCTRL,"-please-enter-comment-",
			wx.wxDefaultPosition,wx.wxSize(600,120),
			wx.wxTE_MULTILINE+wx.wxTE_DONTWRAP)

		local comboContent = SVN_PLUGIN:GetSvnLog()

		comboBox = wx.wxComboBox(dialog,ID_COMBOBOX,TR("Select last recent comment"),
			wx.wxDefaultPosition,wx.wxDefaultSize,
			comboContent,
			wx.wxTE_PROCESS_ENTER)

		mainSizer:Add(textCtrl,0,wx.wxEXPAND+wx.wxALL,5)
		mainSizer:Add(comboBox,0,wx.wxEXPAND+wx.wxALL,5)
	end

	--
	-- the checklist box
	--

	local checkListBox=wx.wxCheckListBox(dialog,ID_CHECKLISTBOX,wx.wxDefaultPosition,wx.wxDefaultSize,FileList)
	mainSizer:Add(checkListBox,0,wx.wxEXPAND+wx.wxALL,5)
	--
	-- the diff control
	--
	local diffCtrl=nil
	if diffallowed then
		diffCtrl=wx.wxTextCtrl(dialog,ID_DIFFCTRL,"...DIFF...",
			wx.wxDefaultPosition,wx.wxSize(800,600),
			wx.wxTE_MULTILINE+wx.wxTE_DONTWRAP+wx.wxTE_RICH+wx.wxTE_READONLY)
		diffCtrl:SetFont(fontCourier)
		mainSizer:Add(diffCtrl,1,wx.wxEXPAND+wx.wxALL,5)
	end

	local buttonSizer = wx.wxBoxSizer( wx.wxHORIZONTAL )

	local okButton = wx.wxButton(dialog,wx.wxID_OK,"Ok") -- NEED this for validators to work
	okButton:Enable(false)
	okButton:SetDefault()

	local cancelButton = wx.wxButton(dialog,wx.wxID_CANCEL,"Cancel")


	buttonSizer:Add( okButton,0,wx.wxALIGN_CENTER+wx.wxALL,5 )
	buttonSizer:Add( cancelButton,0,wx.wxALIGN_CENTER+wx.wxALL,5 )

	mainSizer:Add(   buttonSizer,0,wx.wxALIGN_CENTER+wx.wxALL,5 )

	dialog:SetSizer(mainSizer)
	mainSizer:SetSizeHints(dialog)

	local function HandleComboBoxSelected(event)
		textCtrl:ChangeValue(event:GetString()) -- set comment according to selected combo box item
	end

	local function HandleCheckBoxSelected(event)
		if diffCtrl then
			local check_box_text = event:GetString()
			local cmd=sprintf("svn diff \"%s\"",self:FixPath(check_box_text))
			local output,sts=self:do_command(cmd)
			DiffOutputToTextCtrl(diffCtrl,output)
		end

		local anyChecked=false;
		for i=0,#FileList-1 do
			if checkListBox:IsChecked(i) then
				anyChecked=true
				break
			end
		end
		okButton:Enable(anyChecked)
	end

	-- connect selection of combo box to function
	dialog:Connect(ID_COMBOBOX,wx.wxEVT_COMMAND_COMBOBOX_SELECTED,HandleComboBoxSelected)
	-- connect selcetion of combo box to function
	dialog:Connect(ID_CHECKLISTBOX,wx.wxEVT_COMMAND_CHECKLISTBOX_TOGGLED,HandleCheckBoxSelected)
	dialog:Connect(ID_CHECKLISTBOX,wx.wxEVT_COMMAND_LISTBOX_SELECTED,HandleCheckBoxSelected)

	local result = dialog:ShowModal()

	if result == wx.wxID_OK then

		if action=="resolve" then action="resolve --accept working" end

		local selected_filenames={}
		for i=0,#FileList-1 do
			if checkListBox:IsChecked(i) then
				push(selected_filenames,quote(self:FixPath(checkListBox:GetString(i))))
			end
		end
		selected_filenames=table.concat(selected_filenames," ")

		local cmd
		if textCtrl then
			local comment=textCtrl:GetValue():gsub("^%s+",""):gsub("%s+$","")
			printf("comment is %s\n",vis(comment))
			cmd = "svn "..action..' -m '..'"'..comment..'" '..selected_filenames
		else
			cmd = "svn "..action..' '..selected_filenames
		end
		printf("cmd=[[%s]]\n",cmd)
		self:do_command(cmd,true)
		self:UpdateSvnStatus()
	end
	dialog:Destroy()

end


function SVN_PLUGIN:ShowDiffOutputWindow(Caption,DiffOutput)

	local frame = self.parent
	-- the dialog
	local dialog = wx.wxDialog(frame,wx.wxID_ANY,Caption,
		wx.wxDefaultPosition,wx.wxDefaultSize,
		wx.wxDEFAULT_DIALOG_STYLE+wx.wxRESIZE_BORDER)
	-- the sizer
	local mainSizer = wx.wxBoxSizer(wx.wxVERTICAL)

	local diffText=wx.wxTextCtrl(dialog,wx.wxID_ANY,"",
		wx.wxDefaultPosition,wx.wxSize(800,600),
		wx.wxTE_MULTILINE+wx.wxTE_DONTWRAP+wx.wxTE_RICH)
	diffText:SetFont(fontCourier)
	mainSizer:Add(diffText,1,wx.wxEXPAND+wx.wxALL,5)


	local okButton=wx.wxButton(dialog,wx.wxID_OK,"Close") -- NEED this for validators to work
	okButton:SetDefault()
	local buttonSizer = wx.wxBoxSizer( wx.wxHORIZONTAL )

	buttonSizer:Add(okButton,0,wx.wxALIGN_CENTER+wx.wxALL,5 )
	mainSizer:Add(buttonSizer,0,wx.wxALIGN_CENTER+wx.wxALL,5 )

	dialog:SetSizer(mainSizer)
	mainSizer:SetSizeHints(dialog)

	DiffOutputToTextCtrl(diffText,DiffOutput)
	local result = dialog:ShowModal()
	dialog:Destroy()
end


function SVN_PLUGIN:DoAskAction(title,action,filenames)
	if filenames and #filenames>0 then
		local msg=title.." "..join(filenames,"\n").."?"
		for f=1,#filenames do
			filenames[f]=self:FixPath(filenames[f])
		end

		local cmd="svn "..action.." "..quote(filenames)
		local btn=wx.wxMessageBox(msg.."\n\n("..cmd..")","Subversion",wx.wxOK+wx.wxCANCEL+wx.wxICON_QUESTION)
		if btn==wx.wxOK then
			self:do_command(cmd,true)
			self:UpdateSvnStatus()
		end
	end
end

function SVN_PLUGIN:DoAskUpdate(filenames)
	if #filenames==0 then push(filenames,self.WorkingDir) end
	return self:DoAskAction("Update","update",filenames)
end

function SVN_PLUGIN:DoAskAdd(filenames)
	return self:DoAskAction("Add files","add",filenames)
end

function SVN_PLUGIN:DoAskDelete(filenames)
	return self:DoAskAction("Delete files","delete",filenames)
end



function SVN_PLUGIN:DoShowDiff(filename)
	if filename then
		if path_to_diff_tool then
			local qname=quote(self:FixPath(filename))
			local cmd=path_to_diff_tool.." "..qname
			if path_to_diff_tool:match("{{path}}") then
				cmd=path_to_diff_tool:gsub("{{path}}",qname)
			end
			printf("cmd=[[%s]]\n",cmd)
			os.execute(cmd.." &")
		else
			local cmd="svn diff "..quote(self:FixPath(filename))
			local output,sts=self:do_command(cmd)
			self:ShowDiffOutputWindow(filename,output)
		end
	end
end

function SVN_PLUGIN:GetSelectedListItems()
	local filenames={}
	local itemId=self.svnListCtrl:GetNextItem(-1,wx.wxLIST_NEXT_ALL,wx.wxLIST_STATE_SELECTED)
	while itemId>=0 do
		local itemData=self.svnListCtrl:GetItemData(itemId)
		local entry=self.svnStatusEntries[itemData]
		push(filenames,entry.path)
		itemId=self.svnListCtrl:GetNextItem(itemId,wx.wxLIST_NEXT_ALL,wx.wxLIST_STATE_SELECTED)
	end
	return filenames
end


function SVN_PLUGIN:GetSelectedListItemsForAction(action)
	local filenames={}
	local itemId=self.svnListCtrl:GetNextItem(-1,wx.wxLIST_NEXT_ALL,wx.wxLIST_STATE_SELECTED)
	while itemId>=0 do
		local itemData=self.svnListCtrl:GetItemData(itemId)
		local entry=self.svnStatusEntries[itemData]
		local status=entry.status
		local status_allowed=SVN_STATUS[status] and SVN_STATUS[status].allowed
		if status_allowed and status_allowed[action] then
			push(filenames,entry.path)
		end
		itemId=self.svnListCtrl:GetNextItem(itemId,wx.wxLIST_NEXT_ALL,wx.wxLIST_STATE_SELECTED)
	end
	return filenames
end



function SVN_PLUGIN:OnListCtrlRightClick(event) -- create menu items on svn file tree
	printf("svn: OnListCtrlRightClick(%s)\n",vis(event))
	local selected=self:GetSelectedListItems()
	if #selected==0 then return end
	local enables=self:GetEnablesForFiles(selected)
	local menu = self:CreateMenuFor(enables)
	self.svnListCtrl:PopupMenu(menu)
end


--============================================================
-- this is the main function to create and populate the
-- SVN panel "Pending changes"
--============================================================

function SVN_PLUGIN:CreateSvnPanel(parent)

	self.parent=parent
	--
	-- create panel
	--
	local svnPanel = wx.wxPanel(parent, wx.wxID_ANY)

	--
	-- vertical sizer to put elements
	--
	local vSizer = wx.wxBoxSizer(wx.wxVERTICAL)

	-------------------------------------------------------------------------
	-- Create the action toggle toolbar
	-------------------------------------------------------------------------




	SVN_ACTION.refresh.onClick=function(event)
		self:UpdateSvnStatus()
	end

	SVN_ACTION.update.onClick=function(event)
		self:DoAskUpdate(SVN_PLUGIN:GetSelectedListItemsForAction("update"))
	end

	SVN_ACTION.add.onClick=function(event)
		self:DoAskAdd(SVN_PLUGIN:GetSelectedListItemsForAction("add"))
	end

	SVN_ACTION.delete.onClick=function(event)
		self:DoAskDelete(SVN_PLUGIN:GetSelectedListItemsForAction("delete"))
	end

	SVN_ACTION.diff.onClick=function(event)
		local filenames=SVN_PLUGIN:GetSelectedListItemsForAction("diff")
		if #filenames==1 then
			self:DoShowDiff(filenames[1])
		end
	end

	SVN_ACTION.info.onClick=function(event)

		-- create the dialog frame

		local dialog=wx.wxDialog(parent,wx.wxID_ANY,TR"svn info",wx.wxDefaultPosition,wx.wxDefaultSize)
		local panel = wx.wxPanel(dialog,wx.wxID_ANY)
		local mainSizer = wx.wxBoxSizer(wx.wxVERTICAL)
		local flexGridSizer=wx.wxFlexGridSizer(0,2,0,0)


		local function AddInfo(name,value)
			local staticText=wx.wxStaticText(panel,wx.wxID_ANY,name)
			local textCtrl=wx.wxStaticText(panel,wx.wxID_ANY,value)
			flexGridSizer:Add( staticText,0,wx.wxALIGN_CENTER_VERTICAL+wx.wxALL,1)
			flexGridSizer:Add( textCtrl,0,wx.wxGROW+wx.wxALIGN_LEFT+wx.wxALL,1)
		end


		local info=self:get_svn_xml("info","--xml "..quote(self.WorkingDir))

		local entry=info:element("entry")
		AddInfo("Revision",entry:attribute"revision")
		local url=entry:element("url")
		AddInfo("URL",url:cdata())
		local wcinfo=entry:element("wc-info")
		local path=wcinfo:element("wcroot-abspath")
		AddInfo("Path",path:cdata())

		local commit=entry:element("commit")
		AddInfo("Commit",commit:attribute"revision")
		local author=commit:element("author")
		AddInfo("Author",author:cdata())

		--[[
		<?xml version="1.0" encoding="UTF-8"?>
		<info>
		<entry path="." revision="304757" kind="dir">
		<url>https://localhost/repos/zbs/zbssnv/trunk</url>
		<relative-url>^/zbssvn/trunk</relative-url>
		<repository>
		<root>https://localhost/repos/zbs</root>
		</repository>
		<wc-info>
		<wcroot-abspath>/home/user/proj/zbssvn</wcroot-abspath>
		<schedule>normal</schedule>
		<depth>infinity</depth>
		</wc-info>
		<commit revision="304565">
		<author>John.Doe</author>
		<date>2017-09-06T13:04:16.239276Z</date>
		</commit>
		</entry>
		</info>
		--]]
		--dialog:CreateButtonSizer(wx.wxID_CLOSE)
		local buttonSizer = wx.wxBoxSizer( wx.wxHORIZONTAL )
		local closeButton = wx.wxButton( panel,wx.wxID_OK, "Close")



		mainSizer:Add(      flexGridSizer, 1, wx.wxGROW+wx.wxALIGN_CENTER+wx.wxALL, 5 )


		buttonSizer:Add( closeButton, 0, wx.wxALIGN_CENTER+wx.wxALL, 5 )
		mainSizer:Add(    buttonSizer, 0, wx.wxALIGN_CENTER+wx.wxALL, 5 )



		panel:SetSizer( mainSizer )
		mainSizer:SetSizeHints(dialog )
		dialog:ShowModal()
	end



	local function add(t,k)
		if rawget(t,k) then return end
		push(t,k) t[k]=#t
	end

	SVN_ACTION.ignore.onClick=function(event)
		local filenames=SVN_PLUGIN:GetSelectedListItemsForAction("ignore")
		local directories=setmetatable({},mt_autocreate)
		for _,filename in ipairs(filenames) do
			local dir,name=filename:match("^(.+)/(.+)$")
			if dir then
				push(directories[dir].filenames,name)
				local ext=name:match("%.%w+$")
				if ext then
					add(directories[dir].exts,"*"..ext)
				end
			end
		end
		local commands={}
		local menuEntries={}
		for directory,data in spairs(directories) do
			local n=#commands+1
			local cmd=sprintf("cd \"%s\" && svnignore %s",directory,quote(data.filenames))
			local msg=sprintf("in %s ignore %s",directory,join(data.filenames," "))
			menuEntries[n]={n,msg}
			commands[n]=cmd
			n=n+1
			if #data.exts>0 then
				local cmd=sprintf("cd \"%s\" && svnignore %s",directory,quote(data.exts))
				local msg=sprintf("in %s ignore %s",directory,join(data.exts," "))
				menuEntries[n]={n,msg,cmd=cmd}
				commands[n]=cmd
			end
		end
		local menu = wx.wxMenu(menuEntries)
		local selectedcommand
		menu:Connect(wx.wxID_ANY,wx.wxEVT_COMMAND_MENU_SELECTED,function(event)
				selectedcommand=commands[event:GetId()]
			end)
		self.svnListCtrl:PopupMenu(menu)
		if selectedcommand then
			local btn=wx.wxMessageBox(selectedcommand,"Subversion",wx.wxOK+wx.wxCANCEL+wx.wxICON_QUESTION)
			if btn==wx.wxOK then
				self:do_command(selectedcommand)
				self:UpdateSvnStatus()
			end
		end
	end

	SVN_ACTION.commit.onClick=function(event)
		self:CreateDialog("Commit","commit",SVN_PLUGIN:GetSelectedListItemsForAction("commit"),true,true)
		self.SvnLogComments=nil
	end

	SVN_ACTION.resolve.onClick=function(event)
		self:CreateDialog("Resolve","resolve",SVN_PLUGIN:GetSelectedListItemsForAction("resolve"),false,true)
	end

	SVN_ACTION.revert.onClick=function(event)
		self:CreateDialog("Revert","revert",SVN_PLUGIN:GetSelectedListItemsForAction("revert"),false,true)
	end

	-------------------------------------------------------------------------
	-- Create the action toggle toolbar
	-------------------------------------------------------------------------
	local svnActionShowToolBar = wx.wxToolBar(svnPanel,wx.wxID_ANY,wx.wxDefaultPosition,wx.wxDefaultSize,wx.wxNO_BORDER + wx.wxTB_FLAT)
	self.svnActionShowToolBar=svnActionShowToolBar
	for i,data in ipairs(SVN_ACTION) do
		if data.name then
			local bmp=my_getBitmap("action-"..data.name)
			local toolId=NewID()
			svnActionShowToolBar:AddTool(toolId,data.name,bmp,data.name.." items")
			if data.onClick then
				svnActionShowToolBar:Connect(toolId,wx.wxEVT_COMMAND_TOOL_CLICKED,data.onClick)
			end
			data.actionToolId=toolId
			bmp:delete()
		else
			svnActionShowToolBar:AddSeparator()
		end
	end

	svnActionShowToolBar:AddSeparator()
	svnActionShowToolBar:AddSeparator()

	local function OnToggle(event,status)
		local toolId=event:GetId()
		local show=svnActionShowToolBar:GetToolState(toolId)
		status.show=show
		SVN_PLUGIN:Step3aUpdateSvnListControl()
		SVN_PLUGIN:Step3bUpdateActionToolbar()
	end


	--
	-- add the "show" toggles to the toolbar
	--
	for i,data in ipairs(SVN_STATUS) do
		local show=data.show if show==nil then show=true end
		data.show=show
		local bmp=my_getBitmap("status-"..data.name)
		local toolId=NewID()
		data.statusToolId=toolId
		svnActionShowToolBar:AddTool(toolId,data.name,bmp,"show "..data.name.." items",wx.wxITEM_CHECK )
		svnActionShowToolBar:ToggleTool(toolId,show)
		svnActionShowToolBar:SetToolClientData(toolId,wx.wxObject(data))
		bmp:delete()
		svnActionShowToolBar:Connect(toolId,wx.wxEVT_COMMAND_TOOL_CLICKED,function(event) OnToggle(event,data)end)
	end

	--
	-- required,else icons wont show
	--
	svnActionShowToolBar:Realize()


	local svnListCtrl = wx.wxListCtrl(svnPanel,ID_LISTCONTROL,wx.wxDefaultPosition,wx.wxDefaultSize,
		wx.wxLC_ALIGN_LEFT+	wx.wxLC_REPORT)


	svnListCtrl:Connect(ID_LISTCONTROL,wx.wxEVT_COMMAND_LIST_ITEM_SELECTED,function()
			SVN_PLUGIN:Step3bUpdateActionToolbar()
		end)

	svnListCtrl:Connect(ID_LISTCONTROL,wx.wxEVT_COMMAND_LIST_ITEM_DESELECTED,function()
			SVN_PLUGIN:Step3bUpdateActionToolbar()
		end)

	svnListCtrl:Connect(ID_LISTCONTROL,wx.wxEVT_COMMAND_LIST_ITEM_RIGHT_CLICK,function(event)
			SVN_PLUGIN:OnListCtrlRightClick(event)
		end)

	svnListCtrl:Connect(ID_LISTCONTROL,wx.wxEVT_COMMAND_LIST_ITEM_ACTIVATED,function(event)
			SVN_PLUGIN:OnActivate(event)
		end)



	local svnImageList=CreateImageList("status")
	svnListCtrl:AssignImageList(svnImageList,wx.wxIMAGE_LIST_SMALL)
	svnListCtrl:InsertColumn(0,"Status")
	svnListCtrl:InsertColumn(1,"Path")

	vSizer:Add(svnActionShowToolBar, 0, wx.wxALL + wx.wxGROW , 2)
	vSizer:Add(svnListCtrl, 1, wx.wxALL + wx.wxGROW, 2)
	svnPanel:SetSizer(vSizer)
	vSizer:SetSizeHints(svnPanel)
	self.svnListCtrl=svnListCtrl


	svnListCtrl:Connect(ID_REFRESH,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.refresh.onClick)
	svnListCtrl:Connect(ID_UPDATE,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.update.onClick)
	svnListCtrl:Connect(ID_COMMIT,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.commit.onClick)
	svnListCtrl:Connect(ID_REVERT,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.revert.onClick)
	svnListCtrl:Connect(ID_ADD,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.add.onClick)
	svnListCtrl:Connect(ID_DELETE,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.delete.onClick)
	svnListCtrl:Connect(ID_RESOLVE,wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.resolve.onClick)
	svnListCtrl:Connect(ID_DIFF,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.diff.onClick)
	svnListCtrl:Connect(ID_IGNORE,	wx.wxEVT_COMMAND_MENU_SELECTED,SVN_ACTION.ignore.onClick)

	return svnPanel
end

function SVN_PLUGIN:OnActivate(event)
	local itemId = event:GetIndex()
	if verbose>=2 then printf("SVN_PLUGIN:OnActivate() itemId=%s\n",vist(itemId)) end
	local itemData=self.svnListCtrl:GetItemData(itemId)
	if verbose>=2 then printf("SVN_PLUGIN:OnActivate() itemData=%s\n",vist(itemData))end
	local entry=self.svnStatusEntries[itemData]
	if verbose>=2 then printf("SVN_PLUGIN:OnActivate() entry=%s\n",vist(entry))end
	LoadFile(entry.full_path,nil,true)
end

--
-- Create the SVN Tab (JJvB: Once on onRegister, never deleted again!!!)
--
function SVN_PLUGIN:CreateSvnTab()

	local t1 = gettime()
	--
	-- assign an image list to the toolbar
	--
	ide.filetree.projtreeCtrl:AssignStateImageList(CreateImageList("status"))

	local svnPanel=SVN_PLUGIN:CreateSvnPanel(ide.frame)

	--
	-- add panel according to layout
	--
	local function reconfigure(pane)
		pane:TopDockable(false)
		:BottomDockable(false)
		:MinSize(150,-1)
		:BestSize(300,-1)
		:FloatingSize(200,300)
	end

	-- get the svn panel
	local layout = ide:GetSetting("/view", "uimgrlayout")
	--
	-- add a panel to the Project Notebook
	--
	if not layout or not layout:find("svnpanel") then
		self.panel=ide:AddPanelDocked(ide:GetOutputNotebook(), svnPanel, "svnpanel", TR("Pending Changes"), reconfigure, false)
	else
		self.panel=ide:AddPanel(svnTreeCtrl, "svnpanel", TR("Pending Changes"), reconfigure)
	end

end
--]]
local function is_svn_dir(path)
	local cmd=sprintf("svnversion \"%s\"",path:gsub("[\\/]$",""))
	local output,sts=SVN_PLUGIN:do_command(cmd)
	return output:gsub(":",""):gsub("%s+$",""):match("^%d+%a*$")
end




--============================================================
-- svn processing steps
--============================================================

------------------------------------------------------------
-- read svn status and save parsed output
------------------------------------------------------------
function SVN_PLUGIN:Step1ReadSvnStatus()
	self.svn_status=nil
	if self.WorkingDir then
		local t0=gettime()
		wx.wxBeginBusyCursor()
		self.svn_status=self:get_svn_xml("status","--xml --no-ignore --verbose "..quote(self.WorkingDir))
		wx.wxEndBusyCursor()
		local t1=gettime()
		if verbose>=2 then printf("SVN_PLUGIN:svn status %.3f sec\n",t1-t0) end
	end
end

local function make_rel(path,base)
	if path then
		if path~=base and path:sub(1,#base)==base then
			path=path:sub(#base+2)
		end
		return path
	end
end


function SVN_PLUGIN:Step2ParseSvnStatus()
	local svnStatusEntries={}
	if self.svn_status then
		for status_target in self.svn_status:elements() do
			assert(status_target:tag()=="target")
			local target_path=assert(status_target:attribute"path")
			for target_entry in status_target:elements() do
				assert(target_entry:tag()=="entry")
				local full_path=assert(target_entry:attribute"path")
				local entry_path=make_rel(full_path,target_path)
				local entry_wcstatus=assert(target_entry:element("wc-status"))
				local wcstatus_item=assert(entry_wcstatus:attribute"item")
				local data=
				{
					full_path=full_path,
					status=wcstatus_item,
					path=entry_path,
					moved_from=make_rel(entry_wcstatus["moved-from"],target_path),
					moved_to=make_rel(entry_wcstatus["moved-to"],target_path),
				}
				push(svnStatusEntries,data)
				svnStatusEntries[entry_path]=data
			end
		end
	end
	self.svnStatusEntries=svnStatusEntries
end


------------------------------------------------------------
-- show items selected by the show status
------------------------------------------------------------
function SVN_PLUGIN:Step3aUpdateSvnListControl()
	local t1=gettime()
	local svnListCtrl=self.svnListCtrl
	svnListCtrl:DeleteAllItems()
	if not self.isSvnDir then
		svnListCtrl:InsertItem(1,"-no-svn-dir-")
		svnListCtrl:SetColumnWidth(0,wx.wxLIST_AUTOSIZE);
		return
	end
	local cnt=0
	for i,entry in ipairs(self.svnStatusEntries) do
		local path=entry.path
		local status=entry.status
		if SVN_STATUS[status].show then
			local itemIdx=cnt cnt=cnt+1
			svnListCtrl:InsertItem(itemIdx,status,SVN_STATUS[status].bmpId)
			if entry.moved_from then
				path=sprintf("%s (moved from %s)",path,entry.moved_from)
			end
			if entry.moved_to then
				path=sprintf("%s (moved to %s)",path,entry.moved_to)
			end
			svnListCtrl:SetItem(itemIdx,1,path)
			svnListCtrl:SetItemData(itemIdx,i)
		end
	end

	-- autosize

	svnListCtrl:SetColumnWidth(0,wx.wxLIST_AUTOSIZE);
	svnListCtrl:SetColumnWidth(1,wx.wxLIST_AUTOSIZE);

	local w0=svnListCtrl:GetColumnWidth(0)
	if w0<80 then
		svnListCtrl:SetColumnWidth(0,80);
		w0=svnListCtrl:GetColumnWidth(0)
	end
	local w1=svnListCtrl:GetColumnWidth(1)
	local wlist=svnListCtrl:GetSize():GetWidth()
	if w0+w1<wlist then
		svnListCtrl:SetColumnWidth(1,wlist-w0);
	end
	local t2=gettime()
	if verbose>1 then printf("SVN_PLUGIN:Step3aUpdateSvnListControl(): %.3f sec\n",t2-t1) end
end


function SVN_PLUGIN:GetEnablesForFiles(filenames)
	local enables={}
	-- default enable
	for a,action in ipairs(SVN_ACTION) do
		if action.enable then
			enables[action.name]=1
		end
	end
	-- detect which status available
	local svnStatusEntries=self.svnStatusEntries
	local have_status={}
	for f,filename in ipairs(filenames) do
		local entry=svnStatusEntries[filename]
		if entry then
			have_status[entry.status]=true
		end
	end
	for status in pairs(have_status) do
		local status_allowed=SVN_STATUS[status].allowed
		if status_allowed then
			for action in pairs(status_allowed) do
				enables[action]=true
			end
		end
	end
	return enables
end

------------------------------------------------------------
-- disable/enable action items dependent on selected entries
------------------------------------------------------------
function SVN_PLUGIN:Step3bUpdateActionToolbar()
	--
	-- if not svn then
	--
	if not self.isSvnDir then
		for a,action in ipairs(SVN_ACTION) do
			if action.name then
				self.svnActionShowToolBar:EnableTool(action.actionToolId,false)
			end
		end
		for s,status in ipairs(SVN_STATUS) do
			if status.name then
				self.svnActionShowToolBar:EnableTool(status.statusToolId,false)
			end
		end
		return
	end
	local filenames=self:GetSelectedListItems()
	local enables=self:GetEnablesForFiles(filenames)

	for a,action in ipairs(SVN_ACTION) do
		if action.name then
			local enable=enables[action.name] or false
			self.svnActionShowToolBar:EnableTool(action.actionToolId,enable)
		end
	end
	-- hide all
	for s,status in ipairs(SVN_STATUS) do
		if status.name then
			self.svnActionShowToolBar:EnableTool(status.statusToolId,true)
		end
	end

end


--
-- get svn status and repopulate the SVN tab
--
function SVN_PLUGIN:Step3cUpdateProjectTree()
	local t0=gettime()
	if not self.isSvnDir then return end
	local tree=ide:GetProjectTree()
	--[[ JJvB this will not be functional
	-- as subtrees are populated on open 
	local function traverse(prefix,root)
		local roottext=tree:GetItemText(root)
		printf("%s roottext=%s\n",prefix,vis(roottext))

		local item,cookie = tree:GetFirstChild(root)
		while item:IsOk() do
			--printf("item=%s\n",vis(item))
			local itemtext=tree:GetItemText(item)
			printf("%s itemtext=%s\n",prefix,vis(itemtext))
			if tree:ItemHasChildren(item) then
				traverse(prefix..">",item)
			end
			item, cookie = tree:GetNextChild(root, cookie)
		end
		printf("%s itemIsOk=false\n",prefix)
	end
	traverse(">",tree:GetRootItem())
	--]]
	for e,entry in ipairs(self.svnStatusEntries) do
		local item=tree:FindItem(entry.path)
		local id=SVN_STATUS[entry.status].bmpId
		if item and id then
			tree:SetItemState(item,id)
		end
	end
	local t1=gettime()
	if verbose>1 then printf("SVN_PLUGIN:Step3cUpdateProjectTree(): %.3f sec\n",t1-t0) end

end


function SVN_PLUGIN:UpdateSvnStatus()
	if verbose>=1 then print("SVN_PLUGIN:UpdateSvnStatus()") end
	self.svn_status=nil
	self.svnStatusEntries=nil
	local isSvnDir=self.WorkingDir and is_svn_dir(self.WorkingDir)
	self.isSvnDir=isSvnDir
	if not isSvnDir then
		printf("svn:no svn dir\n")
		self:Step3aUpdateSvnListControl()
		self:Step3bUpdateActionToolbar()
		self:Step3cUpdateProjectTree()

		return
	end

	self:Step1ReadSvnStatus()
	self:Step2ParseSvnStatus()
	self:Step3aUpdateSvnListControl()
	self:Step3bUpdateActionToolbar()
	self:Step3cUpdateProjectTree()
end


local function DeleteCustomerPage(projnotebook, page_name)
	local count = projnotebook:GetPageCount()
	if count >  1 then
		for pos = 0, count-1 do
			if projnotebook:GetPageText(pos) == page_name then
				DisplayOutputLn("svn: page to delete found  at position:  ",  pos)
				projnotebook:DeletePage(pos)
			end
		end
	end
end



------------------------------------------------------------
-- get items from the tree
-- return {list-of-selected},focused
------------------------------------------------------------
function SVN_PLUGIN:GetSelectedTreeItems()
	local tree=ide:GetProjectTree()
	local rootId=tree:GetRootItem()
	local rootText=tree:GetItemText(rootId)
	local function GetText(itemId)
		if itemId:IsOk() then
			local parentItemId=tree:GetItemParent(itemId)
			if parentItemId:IsOk() then
				local parentText=GetText(parentItemId)
				if parentText~=rootText then
					return parentText.."/"..tree:GetItemText(itemId)
				end
			end
			return tree:GetItemText(itemId)
		end
	end
	local selected={}
	if tree:HasFlag(wx.wxTR_MULTIPLE) then
		for i,treeItemId in ipairs(tree:GetSelections()) do
			push(selected,GetText(treeItemId))
		end
	else
		push(selected,GetText(tree:GetSelection()))
	end
	local focused=GetText(tree:GetFocusedItem())
	if verbose>1 then printf("SVN_PLUGIN:selected=%s,focused=%s\n",vist(selected),vis(focused)) end
	return selected,focused
end

local function onMenuRefresh()
	DisplayOutputLn("svn: onMenuRefresh() called")
	SVN_PLUGIN:UpdateSvnStatus()
end

local function onMenuUpdate()
	SVN_PLUGIN:DoAskUpdate(SVN_PLUGIN:GetSelectedTreeItems())
end

local function onMenuCommit()
	DisplayOutputLn("svn: onCommit() called")
	local selectedItemTexts=SVN_PLUGIN:GetSelectedTreeItems()
	if selectedItemTexts and #selectedItemTexts>0 then
		SVN_PLUGIN:CreateDialog("Commit Files", "commit",selectedItemTexts,true,true)
	end
end

local function onMenuAdd()
	DisplayOutputLn("svn: onAdd() called")
	SVN_PLUGIN:DoAskAdd(SVN_PLUGIN:GetSelectedTreeItems())
end

local function onMenuRevert()
	DisplayOutputLn("svn: onRevert() called")
	local selectedItemTexts=SVN_PLUGIN:GetSelectedTreeItems()
	if selectedItemTexts and #selectedItemTexts>0 then
		SVN_PLUGIN:CreateDialog("Revert Files", "revert",selectedItemTexts,false,true)
	end
end

local function onMenuResolve()
	DisplayOutputLn("svn: onResolve() called")
	local selectedItemTexts=SVN_PLUGIN:GetSelectedTreeItems()
	if selectedItemTexts and #selectedItemTexts>0 then
		SVN_PLUGIN:CreateDialog("Resolve Files", "resolved",selectedItemTexts,false,true)
	end
end

local function onMenuDelete()
	SVN_PLUGIN:DoAskDelete(SVN_PLUGIN:GetSelectedTreeItems())
end

local function onMenuDiff(event)
	printf("SVN_PLUGIN:onDiff(%s)\n",vis(event)) 
	-- is a xwCommandEvent
	local _,focused=SVN_PLUGIN:GetSelectedTreeItems()
	return SVN_PLUGIN:DoShowDiff(focused)
end


function SVN_PLUGIN:onRegister()
	printf=function(...)
		local ok,msg=pcall(sprintf,...)
		msg=msg:gsub("%s+$","")
		DisplayOutputLn(msg)
	end
	if verbose>=1 then
		printf("SVN_PLUGIN:onRegister(%s)\n",vis(self))
		printf("sourcedir=%s\n",sourcedir)
	end
	self:CreateSvnTab()


	------------------------------------------------------------
	-- create a menu entry in the IDE
	------------------------------------------------------------
	local idemenubar=ide:GetMenuBar()
	local svnmenu = wx.wxMenu {
		{ ID_REFRESH , TR("SVN refresh"), TR("Refresh SVN tab")},
		{ ID_UPDATE  , TR("SVN update") , TR("Update project tree from svn")},
	}
	self.svnmenu=svnmenu
	idemenubar:Append(svnmenu, "&SVN")
	local mainframe=ide:GetMainFrame()
	mainframe:Connect(ID_REFRESH,	wx.wxEVT_COMMAND_MENU_SELECTED,onMenuRefresh)
	mainframe:Connect(ID_UPDATE,	wx.wxEVT_COMMAND_MENU_SELECTED,onMenuUpdate)

	-- connect all svn actions to functions
	--]]
	------------------------------------------------------------
	-- connect all svn actions available in the tree
	------------------------------------------------------------
	local tree=ide:GetProjectTree()
	tree:Connect(ID_UPDATE,	wx.wxEVT_COMMAND_MENU_SELECTED,onMenuUpdate)
	tree:Connect(ID_REVERT, wx.wxEVT_COMMAND_MENU_SELECTED,onMenuRevert)
	tree:Connect(ID_ADD, 	wx.wxEVT_COMMAND_MENU_SELECTED,onMenuAdd)
	tree:Connect(ID_DELETE, wx.wxEVT_COMMAND_MENU_SELECTED,onMenuDelete)
	tree:Connect(ID_RESOLVE,wx.wxEVT_COMMAND_MENU_SELECTED,onMenuResolve)
	tree:Connect(ID_COMMIT, wx.wxEVT_COMMAND_MENU_SELECTED,onMenuCommit)
	tree:Connect(ID_DIFF, 	wx.wxEVT_COMMAND_MENU_SELECTED,onMenuDiff)
end

function SVN_PLUGIN:onUnRegister()
	-- toDo remove/detach menu entries ; detach/remove svn tag
	if verbose>=1 then DisplayOutputLn("SVN_PLUGIN:onUnRegister()",  self) end

	--ide.filetree.projtreeCtrl:AssignStateImageList(wx.wxNULL)

	local idemenubar=ide:GetMenuBar()
	local svnmenupos=idemenubar:FindMenu("&SVN")
	if svnmenupos>=0 then
		local svnmenu=idemenubar:Remove(svnmenupos)
	end

	if ide.RemovePanel and self.panel then
		ide:RemovePanel("svnpanel") 
		self.panel=nil
	end
--	local tb = ide:GetToolBar()
--	tb:DeleteTool(tool)
--	tb:Realize()
--	DeleteCustomerPage(ide:GetProjectNotebook(), TR('SVN'))  -- remove old page including all subitems
--	_svn_tree = nil
	--- _selected_files = nil -- store all selected files here

end


function SVN_PLUGIN:onProjectLoad(project_dir)
	if verbose>=1 then printf("SVN_PLUGIN:onProjectLoad(%s)",vis(project_dir)) end
	self.SvnLogComments=nil
	self.WorkingDir=project_dir:gsub("[\\/]$","")
	self:UpdateSvnStatus()
end

function SVN_PLUGIN:onProjectClose(project_dir)
	self.SvnLogComments=nil
	self.WorkingDir=nil
	self.isSvnDir=nil
	self:UpdateSvnStatus()
	printf("SVN_PLUGIN:onProjectClose(%s)",vis(project_dir)) 
end

---[[ Uncomment this to see event names printed in the Output window


function SVN_PLUGIN:onMenuFiletree(menu,tree,event)
	if verbose>=1 then printf("SVN_PLUGIN:onMenuFiletree(%s,%s,%s)",vis(menu),vis(tree),vis(event))end
	local selected,focused=self:GetSelectedTreeItems()
	if #selected==0 then selected={focused} end
	local enables=self:GetEnablesForFiles(selected)
	if next(enables)==nil then return end
	menu:AppendSeparator();	
	local svnmenu=self:CreateMenuFor(enables)
	menu:AppendSubMenu(svnmenu,"SVN")
end

function SVN_PLUGIN:GetSvnEntry(path)

	local WorkingDir=self.WorkingDir
	if not WorkingDir then return nil end -- no open project

	local svnStatusEntries=self.svnStatusEntries
	if not svnStatusEntries then return nil end -- not subversion

	-- make relative, if in working dir
	local wxFileName=wx.wxFileName(path)
	wxFileName:MakeRelativeTo(WorkingDir)
	path=wxFileName:GetFullPath()
	return svnStatusEntries[path]
end

--
-- NOTE for the onFiletreeFilePreXXXX
-- return of false will make ZBS ignore the reqest
-- any other return will make ZBS handle the request
--

function SVN_PLUGIN:onFiletreeFilePreRename(tree,id,src,dst)
	
	-- if not subversion
	if not self.isSvnDir then 
		return  -- let zbs do the job
	end
	
	printf("SVN_PLUGIN:onFiletreeFilePreRename(source=%s,dest=%s)",vis(src),vis(dst))
	local srcEntry=self:GetSvnEntry(src)
	if not srcEntry then
		local msg=sprintf("src %s is not in subversion\n",vis(src))
		local btn=wx.wxMessageBox(msg,"Subversion",wx.wxCANCEL)
		return -- let zbs do the job
	end
	local dstEntry=self:GetSvnEntry(dst)
	if dstEntry then
		local msg=sprintf("dst %s is in subversion\n",vis(src))
		local btn=wx.wxMessageBox(msg,"Subversion",wx.wxCANCEL)
		return -- let zbs do the job
	end
	local cmd="svn rename "..quote(src).." "..quote(dst)
	local msg=sprintf("svn rename\n%s : %s\n%s : %s\n%s",
		vis(src),vist(srcEntry),
		vis(dst),vist(dstEntry),
		cmd
	)
	local btn=wx.wxMessageBox(msg,"Subversion",wx.wxYES+wx.wxNO)
	if btn==wx.wxNO then return false end
	self:do_command(cmd,true)
	self:UpdateSvnStatus()
	ide:GetProjectTree():RefreshChildren()
	return false
end

--GIN:onFiletreeFilePreDelete(
-- userdata: 0x40cb1340 [wxTreeCtrl(0x1272ee0, 381)],
-- userdata: 0x415abe60 [wxTreeItemId(0x178c3f0, 384)],"/home/proj/Lua/ZBS/zbs-svn-tab/TESTSTAT/modified",nil)

function SVN_PLUGIN:onFiletreeFilePreDelete(tree,id,source)
	
	-- if not subversion
	if not self.isSvnDir then 
		return  -- let zbs do the job
	end
	
	
	printf("SVN_PLUGIN:onFiletreeFilePreDelete(source=%s)",vis(source))
	--
	-- lookup entry
	--
	local sourceEntry=self:GetSvnEntry(source)
	--
	-- if not in SVN then let ZBS do its normal action
	--
	if sourceEntry==nil then return end
	--
	--
	--
	if sourceEntry.status=="normal" then
		local cmd="svn delete "..quote(source)
		local msg=sprintf("svn delete %s?\n%s\n%s",vis(source),vist(sourceEntry),cmd)
		local btn=wx.wxMessageBox(msg,"Subversion",wx.wxYES+wx.wxNO)
		if btn==wx.wxNO then return true end
		self:do_command(cmd,true)
		self:UpdateSvnStatus()
		return false
	end
	local cmd="svn delete --force "..quote(source)
	local msg=sprintf("REALLY delete %s\nis %s\n%s",vis(source),vist(sourceEntry),cmd)
	local btn=wx.wxMessageBox(msg,"Subversion",wx.wxYES+wx.wxNO+wx.wxICON_EXCLAMATION)
	if btn==wx.wxNO then return false end
	self:do_command(cmd,true)
	self:UpdateSvnStatus()
	ide:GetProjectTree():RefreshChildren()
	return false
end

--[[ this is of no use for us
function SVN_PLUGIN:onFiletreeFileDelete(a,b,c,d)
	printf("SVN_PLUGIN:onFiletreeFileDelete(%s,%s,%s,%s)",vis(a),vis(b),vis(c),vis(d))
end

function SVN_PLUGIN:onFiletreeFileRemove(a,b,c,d)
	printf("SVN_PLUGIN:onFiletreeFileRemove(%s,%s,%s,%s)",vis(a),vis(b),vis(c),vis(d))
end

function SVN_PLUGIN:onFiletreeFileAdd(a,b,c,d)
	printf("SVN_PLUGIN:onFiletreeFileAdd(%s,%s,%s,%s)",vis(a),vis(b),vis(c),vis(d))
end

function SVN_PLUGIN:onFiletreeFileRefresh(a,b,c,d)
	printf("SVN_PLUGIN:onFiletreeFileRefresh(%s,%s,%s,%s)",vis(a),vis(b),vis(c),vis(d))
end

function SVN_PLUGIN:onEditorPreSave(editor,filePath)
	printf("SVN_PLUGIN:onEditorPreSave(editor=%s,filePath=%s)",vis(editor),vis(filePath))
end
--]]

function SVN_PLUGIN:onEditorSave(editor)
	if verbose>=1 then
		DisplayOutputLn("SVN_PLUGIN:onEditorSave()")
	end
	self:UpdateSvnStatus()
end

--]]
--printf("---- end load SVN_Plugin ----\n")
return SVN_PLUGIN

