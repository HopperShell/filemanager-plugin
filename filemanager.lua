VERSION = "4.0.0"

local micro = import("micro")
local config = import("micro/config")
local buffer = import("micro/buffer")
local shell = import("micro/shell")
local os = import("os")
local filepath = import("filepath")
local runtime = import("runtime")

-- =============================================================================
-- CONFIGURATION
-- =============================================================================

function init()
	config.RegisterCommonOption("filemanager", "showdotfiles", true)

	config.RegisterCommonOption("filemanager", "compressparent", true)
	config.RegisterCommonOption("filemanager", "foldersfirst", true)
	config.RegisterCommonOption("filemanager", "openonstart", false)
	config.RegisterCommonOption("filemanager", "treewidth", 30)
	config.RegisterCommonOption("filemanager", "followactive", true)
	config.RegisterCommonOption("filemanager", "showsize", false)
	config.RegisterCommonOption("filemanager", "showperms", false)
	config.RegisterCommonOption("filemanager", "trashdefault", true)
	config.RegisterCommonOption("filemanager", "vimbindings", true)

	config.MakeCommand("tree", toggle_tree, config.NoComplete)
	config.MakeCommand("rename", rename_at_cursor, config.NoComplete)
	config.MakeCommand("touch", new_file, config.NoComplete)
	config.MakeCommand("mkdir", new_dir, config.NoComplete)
	config.MakeCommand("rm", prompt_delete_at_cursor, config.NoComplete)
	config.MakeCommand("rm!", force_delete_at_cursor, config.NoComplete)
	config.MakeCommand("copy", copy_at_cursor, config.NoComplete)
	config.MakeCommand("cut", cut_at_cursor, config.NoComplete)
	config.MakeCommand("paste", paste_clipboard, config.NoComplete)
	config.MakeCommand("bookmark", bookmark_current_dir, config.NoComplete)
	config.MakeCommand("bookmarks", open_bookmarks, config.NoComplete)

	config.AddRuntimeFile("filemanager", config.RTSyntax, "syntax.yaml")

	if config.GetGlobalOption("filemanager.openonstart") then
		open_tree()
		if tree_view ~= nil then
			micro.CurPane():NextSplit()
		end
	end
end

-- =============================================================================
-- STATE
-- =============================================================================

local tree_view = nil
local current_dir = ""
local highest_visible_indent = 0
local scanlist = {}

-- Clipboard for copy/cut/paste
local clipboard = {
	paths = {},    -- list of absolute paths
	mode = nil,    -- "copy" or "cut"
}

-- Multi-select state
local selected = {}  -- set of absolute paths -> true

-- Search state
local search_query = ""
local search_matches = {}  -- list of scanlist indices
local search_index = 0

-- Git status cache

-- Bookmarks
local bookmarks = {}

-- Debounce
local last_refresh_time = 0

-- =============================================================================
-- UTILITIES
-- =============================================================================

local function repeat_str(str, len)
	local t = {}
	for i = 1, len do
		t[i] = str
	end
	return table.concat(t)
end

local function is_dir(path)
	local info, err = os.Stat(path)
	if info ~= nil then
		return info:IsDir()
	end
	return nil
end

local function get_basename(path)
	if path == nil then return nil end
	return filepath.Base(path)
end

local function is_dotfile(name)
	return string.sub(name, 1, 1) == "."
end

local function path_exists(path)
	local info, err = os.Stat(path)
	if err ~= nil then
		return os.IsExist(err)
	end
	return info ~= nil
end

local function dirname_and_join(path, name)
	return filepath.Join(filepath.Dir(path), name)
end

local function get_working_dir()
	local wd, _ = os.Getwd()
	return wd
end

local function is_macos()
	return runtime.GOOS == "darwin"
end

local function format_size(size)
	if size < 1024 then
		return string.format("%dB", size)
	elseif size < 1024 * 1024 then
		return string.format("%.1fK", size / 1024)
	elseif size < 1024 * 1024 * 1024 then
		return string.format("%.1fM", size / (1024 * 1024))
	else
		return string.format("%.1fG", size / (1024 * 1024 * 1024))
	end
end

local function format_perms(mode)
	local function rwx(bits)
		local r = (bits >= 4) and "r" or "-"
		bits = bits % 4
		local w = (bits >= 2) and "w" or "-"
		bits = bits % 2
		local x = (bits >= 1) and "x" or "-"
		return r .. w .. x
	end
	local m = mode % 512 -- octal 0777
	local owner = math.floor(m / 64)
	local group = math.floor((m % 64) / 8)
	local other = m % 8
	return rwx(owner) .. rwx(group) .. rwx(other)
end


-- =============================================================================
-- TREE DATA MODEL (scanlist + ownership)
-- =============================================================================

local function new_listobj(p, d, o, i)
	return {
		abspath = p,
		dirmsg = d,
		owner = o,
		indent = i,
		decrease_owner = function(self, n)
			self.owner = self.owner - n
		end,
		increase_owner = function(self, n)
			self.owner = self.owner + n
		end,
	}
end

local function get_scanlist(dir, ownership, indent_n)
	local dir_scan, err = os.ReadDir(dir)
	if dir_scan == nil then
		micro.InfoBar():Error("Error scanning dir: ", tostring(err))
		return nil
	end

	local results = {}
	local files = {}

	local show_dotfiles = config.GetGlobalOption("filemanager.showdotfiles")
	local folders_first = config.GetGlobalOption("filemanager.foldersfirst")

	for i = 1, #dir_scan do
		local name = dir_scan[i]:Name()
		local show = true
		if not show_dotfiles and is_dotfile(name) then show = false end
		if show then
			local abspath = filepath.Join(dir, name)
			local dirmsg = is_dir(abspath) and "+" or ""
			local obj = new_listobj(abspath, dirmsg, ownership, indent_n)
			if folders_first and dirmsg == "" then
				files[#files + 1] = obj
			else
				results[#results + 1] = obj
			end
		end
	end

	for i = 1, #files do
		results[#results + 1] = files[i]
	end

	return results
end

local function scanlist_is_empty()
	return next(scanlist) == nil
end

local function get_safe_y(optional_y)
	if optional_y == nil then
		if tree_view == nil then return 0 end
		optional_y = tree_view.Cursor.Loc.Y
	end
	if optional_y > 2 then
		return optional_y - 2
	end
	return 0
end

-- =============================================================================
-- SELECTION (Multi-select)
-- =============================================================================

local function is_selected(abspath)
	return selected[abspath] == true
end

local function toggle_select(abspath)
	if selected[abspath] then
		selected[abspath] = nil
	else
		selected[abspath] = true
	end
end

local function clear_selection()
	selected = {}
end

local function get_selected_paths()
	local paths = {}
	-- If we have multi-select, use those
	for path, _ in pairs(selected) do
		paths[#paths + 1] = path
	end
	-- If nothing selected, use cursor
	if #paths == 0 then
		local y = get_safe_y()
		if y > 0 and not scanlist_is_empty() then
			paths[#paths + 1] = scanlist[y].abspath
		end
	end
	return paths
end

local function select_count()
	local n = 0
	for _ in pairs(selected) do n = n + 1 end
	return n
end

-- =============================================================================
-- RENDERING
-- =============================================================================

local function refresh_view()
	if tree_view == nil then return end

	local buf = tree_view.Buf
	local tw = config.GetGlobalOption("filemanager.treewidth") or 30

	local show_size = config.GetGlobalOption("filemanager.showsize")
	local show_perms = config.GetGlobalOption("filemanager.showperms")

	-- Build the full content as a single string
	local lines = {}

	-- Header: current dir, separator, ..
	lines[#lines + 1] = current_dir
	lines[#lines + 1] = repeat_str("─", tw)
	lines[#lines + 1] = ".."

	for i = 1, #scanlist do
		local entry = scanlist[i]
		local name = get_basename(entry.abspath)
		local display = ""

		-- Selection marker
		local sel_marker = is_selected(entry.abspath) and "● " or ""

		-- Metadata columns
		local meta = ""
		if show_size or show_perms then
			local info, _ = os.Stat(entry.abspath)
			if info ~= nil then
				if show_perms then
					meta = meta .. format_perms(info:Mode()) .. " "
				end
				if show_size then
					if not info:IsDir() then
						meta = meta .. format_size(info:Size()) .. " "
					else
						meta = meta .. "     "
					end
				end
			end
		end

		-- Build display line
		if entry.dirmsg ~= "" then
			display = sel_marker .. entry.dirmsg .. " " .. name .. "/"
		else
			display = sel_marker .. "  " .. name
		end

		if meta ~= "" then
			display = display .. "  " .. meta
		end

		-- Indentation
		if entry.owner > 0 then
			display = repeat_str("  ", entry.indent) .. display
		end

		lines[#lines + 1] = display
	end

	-- Replace entire buffer content at once
	local content = table.concat(lines, "\n")
	local numlines = buf:LinesNum()
	local lastline = buf:Line(numlines - 1)
	local lastlen = #lastline

	buf.EventHandler:Remove(buffer.Loc(0, 0), buffer.Loc(lastlen, numlines - 1))
	buf.EventHandler:Insert(buffer.Loc(0, 0), content)

	-- Resize
	if micro.CurTab() ~= nil then
		micro.CurTab():Resize()
	end
end

local function select_line(last_y)
	if tree_view == nil then return end
	if last_y ~= nil then
		if last_y > 1 then
			tree_view.Cursor.Loc.Y = last_y
		end
	elseif tree_view.Cursor.Loc.Y < 2 then
		tree_view.Cursor.Loc.Y = 2
	end
	tree_view.Cursor:Relocate()
	tree_view.Cursor:SelectLine()
end

local function move_cursor_top()
	if tree_view == nil then return end
	tree_view.Cursor.Loc.Y = 2
	select_line()
end

local function refresh_and_select()
	local last_y = nil
	if tree_view ~= nil then
		last_y = tree_view.Cursor.Loc.Y
	end
	refresh_view()
	select_line(last_y)
end

-- =============================================================================
-- DIRECTORY OPERATIONS
-- =============================================================================

local function compress_target(y, delete_y)
	if y == 0 or scanlist_is_empty() then return end

	if scanlist[y].dirmsg == "-" then
		local delete_under = { y }
		local new_table = {}
		local del_count = 0

		for i = 1, #scanlist do
			local delete_index = false
			if i ~= y then
				for x = 1, #delete_under do
					if scanlist[i].owner == delete_under[x] then
						delete_index = true
						del_count = del_count + 1
						if scanlist[i].dirmsg == "-" then
							delete_under[#delete_under + 1] = i
						end
						if scanlist[i].indent == highest_visible_indent and scanlist[i].indent > 0 then
							highest_visible_indent = highest_visible_indent - 1
						end
						break
					end
				end
			end
			if not delete_index then
				new_table[#new_table + 1] = scanlist[i]
			end
		end

		scanlist = new_table

		if del_count > 0 then
			for i = y + 1, #scanlist do
				if scanlist[i].owner > y then
					scanlist[i]:decrease_owner(del_count)
				end
			end
		end

		if not delete_y then
			scanlist[y].dirmsg = "+"
		end
	elseif config.GetGlobalOption("filemanager.compressparent") and not delete_y then
		goto_parent_dir()
		return
	end

	if delete_y then
		local second_table = {}
		for i = 1, #scanlist do
			if i == y then
				for x = i + 1, #scanlist do
					if scanlist[x].owner > y then
						scanlist[x]:decrease_owner(1)
					end
				end
			else
				second_table[#second_table + 1] = scanlist[i]
			end
		end
		scanlist = second_table
	end

	refresh_and_select()
end

local function uncompress_target(y)
	if y == 0 or scanlist_is_empty() then return end
	if scanlist[y].dirmsg ~= "+" then return end

	local scan_results = get_scanlist(scanlist[y].abspath, y, scanlist[y].indent + 1)
	if scan_results ~= nil and #scan_results > 0 then
		local new_table = {}
		for i = 1, #scanlist do
			new_table[#new_table + 1] = scanlist[i]
			if i == y then
				for x = 1, #scan_results do
					new_table[#new_table + 1] = scan_results[x]
				end
				for inner_i = y + 1, #scanlist do
					if scanlist[inner_i].owner > y then
						scanlist[inner_i]:increase_owner(#scan_results)
					end
				end
			end
		end
		scanlist = new_table
	end

	scanlist[y].dirmsg = "-"

	if scan_results ~= nil and #scan_results > 0 then
		if scanlist[y].indent > highest_visible_indent then
			highest_visible_indent = scanlist[y].indent
		end
	end

	refresh_and_select()
end

local function update_current_dir(path)
	highest_visible_indent = 0
	current_dir = path

	-- Refresh git status for the new dir


	local scan_results = get_scanlist(path, 0, 0)
	if scan_results ~= nil then
		scanlist = scan_results
	else
		scanlist = {}
	end

	refresh_view()
	move_cursor_top()
end

local function go_back_dir()
	local one_back = filepath.Dir(current_dir)
	if one_back ~= current_dir then
		update_current_dir(one_back)
	end
end

-- =============================================================================
-- FILE OPENING
-- =============================================================================

local function try_open_at_y(y)
	if y == 2 then
		go_back_dir()
	elseif y > 2 and not scanlist_is_empty() then
		local idx = y - 2
		if scanlist[idx].dirmsg ~= "" then
			update_current_dir(scanlist[idx].abspath)
		else
			-- Set cursor and highlight on the correct line BEFORE switching panes
			tree_view.Cursor.Loc.Y = y
			tree_view.Cursor.Loc.X = 0
			tree_view.Cursor:Relocate()
			tree_view.Cursor:SelectLine()

			local buf, _ = buffer.NewBufferFromFile(scanlist[idx].abspath)
			-- Switch to the editor pane and open file there
			tree_view:NextSplit()
			micro.CurPane():OpenBuffer(buf)
		end
	end
end

local function try_open_in_tab(y)
	if y > 2 and not scanlist_is_empty() then
		local idx = y - 2
		if scanlist[idx].dirmsg == "" then
			local buf, _ = buffer.NewBufferFromFile(scanlist[idx].abspath)
			micro.CurPane():HSplitIndex(buf, true)
		end
	end
end

-- =============================================================================
-- FILE OPERATIONS
-- =============================================================================

local function trash_file(path)
	if is_macos() then
		-- macOS: use mv to ~/.Trash
		local name = get_basename(path)
		local trash_path = filepath.Join(os.Getenv("HOME"), ".Trash", name)
		-- Handle name collision in trash
		if path_exists(trash_path) then
			local ts = tostring(os.Getenv("EPOCHREALTIME") or math.random(10000, 99999))
			trash_path = trash_path .. "." .. ts
		end
		local err = os.Rename(path, trash_path)
		return err
	else
		-- Linux: try trash-cli, fall back to XDG trash
		local out, err = shell.RunCommand('trash-put "' .. path .. '"')
		if err ~= nil then
			-- Fallback: try gio trash
			out, err = shell.RunCommand('gio trash "' .. path .. '"')
		end
		if err ~= nil then
			return err
		end
		return nil
	end
end

function prompt_delete_at_cursor(bp, args)
	if tree_view == nil then return end
	local paths = get_selected_paths()
	if #paths == 0 then
		micro.InfoBar():Error("Nothing to delete")
		return
	end

	local use_trash = config.GetGlobalOption("filemanager.trashdefault")
	local action_word = use_trash and "trash" or "delete"
	local msg = "Do you want to " .. action_word .. " " .. #paths .. " item(s)? "

	micro.InfoBar():YNPrompt(msg, function(yes, cancelled)
		if yes and not cancelled then
			for _, path in ipairs(paths) do
				local err
				if use_trash then
					err = trash_file(path)
				else
					err = os.RemoveAll(path)
				end
				if err ~= nil then
					micro.InfoBar():Error("Failed to " .. action_word .. ": ", tostring(err))
					return
				end
			end
			clear_selection()
			micro.InfoBar():Message(action_word .. "d " .. #paths .. " item(s)")
			-- Remove from scanlist
			for _, path in ipairs(paths) do
				for i = 1, #scanlist do
					if scanlist[i] ~= nil and scanlist[i].abspath == path then
						compress_target(i, true)
						break
					end
				end
			end
		end
	end)
end

function force_delete_at_cursor(bp, args)
	if tree_view == nil then return end
	local paths = get_selected_paths()
	if #paths == 0 then
		micro.InfoBar():Error("Nothing to delete")
		return
	end

	micro.InfoBar():YNPrompt("PERMANENTLY delete " .. #paths .. " item(s)? ", function(yes, cancelled)
		if yes and not cancelled then
			for _, path in ipairs(paths) do
				local err = os.RemoveAll(path)
				if err ~= nil then
					micro.InfoBar():Error("Failed to delete: ", tostring(err))
					return
				end
			end
			clear_selection()
			micro.InfoBar():Message("Deleted " .. #paths .. " item(s)")
			for _, path in ipairs(paths) do
				for i = 1, #scanlist do
					if scanlist[i] ~= nil and scanlist[i].abspath == path then
						compress_target(i, true)
						break
					end
				end
			end
		end
	end)
end

function rename_at_cursor(bp, args)
	if micro.CurPane() ~= tree_view then
		micro.InfoBar():Message("Rename only works in the tree!")
		return
	end
	if args == nil or #args < 1 then
		micro.InfoBar():Error('Usage: rename <newname>')
		return
	end

	local y = get_safe_y()
	if y == 0 then
		micro.InfoBar():Error("Can't rename that!")
		return
	end

	local old_path = scanlist[y].abspath
	local new_path = dirname_and_join(old_path, args[1])
	local err = os.Rename(old_path, new_path)
	if err ~= nil then
		micro.InfoBar():Error("Rename failed: ", tostring(err))
		return
	end

	if not path_exists(new_path) then
		micro.InfoBar():Error("Path doesn't exist after rename!")
		return
	end

	scanlist[y].abspath = new_path
	refresh_and_select()
	micro.InfoBar():Message("Renamed to: ", get_basename(new_path))
end

local function create_filedir(name, make_dir)
	if micro.CurPane() ~= tree_view then
		micro.InfoBar():Message("Cursor must be in the tree!")
		return
	end
	if name == nil then
		micro.InfoBar():Error("You need to provide a name!")
		return
	end

	local y = get_safe_y()
	local filedir_path
	local empty = scanlist_is_empty()

	if not empty and y ~= 0 then
		if scanlist[y].dirmsg ~= "" then
			filedir_path = filepath.Join(scanlist[y].abspath, name)
		else
			filedir_path = dirname_and_join(scanlist[y].abspath, name)
		end
	else
		filedir_path = filepath.Join(current_dir, name)
	end

	if path_exists(filedir_path) then
		micro.InfoBar():Error("A file/dir with that name already exists")
		return
	end

	if make_dir then
		os.Mkdir(filedir_path, os.ModePerm)
	else
		local f, err = os.Create(filedir_path)
		if f ~= nil then f:Close() end
	end

	if not path_exists(filedir_path) then
		micro.InfoBar():Error("Creation failed")
		return
	end

	local new_obj = new_listobj(filedir_path, (make_dir and "+" or ""), 0, 0)
	local last_y

	if not empty and y ~= 0 then
		last_y = tree_view.Cursor.Loc.Y + 1
		if scanlist[y].dirmsg == "+" then
			return  -- Created inside compressed dir, hidden
		elseif scanlist[y].dirmsg == "-" then
			new_obj.owner = y
			new_obj.indent = scanlist[y].indent + 1
		else
			new_obj.owner = scanlist[y].owner
			new_obj.indent = scanlist[y].indent
		end

		local new_table = {}
		for i = 1, #scanlist do
			new_table[#new_table + 1] = scanlist[i]
			if i == y then
				new_table[#new_table + 1] = new_obj
				for inner_i = y + 1, #scanlist do
					if scanlist[inner_i].owner > y then
						scanlist[inner_i]:increase_owner(1)
					end
				end
			end
		end
		scanlist = new_table
	else
		scanlist[#scanlist + 1] = new_obj
		last_y = #scanlist + 2
	end

	refresh_view()
	select_line(last_y)
	micro.InfoBar():Message("Created: ", name)
end

function new_file(bp, args)
	if args == nil or #args < 1 then
		micro.InfoBar():Error('Usage: touch <filename>')
		return
	end
	create_filedir(args[1], false)
end

function new_dir(bp, args)
	if args == nil or #args < 1 then
		micro.InfoBar():Error('Usage: mkdir <dirname>')
		return
	end
	create_filedir(args[1], true)
end

-- =============================================================================
-- COPY / CUT / PASTE
-- =============================================================================

function copy_at_cursor(bp, args)
	local paths = get_selected_paths()
	if #paths == 0 then
		micro.InfoBar():Error("Nothing to copy")
		return
	end
	clipboard.paths = paths
	clipboard.mode = "copy"
	micro.InfoBar():Message("Copied " .. #paths .. " item(s)")
end

function cut_at_cursor(bp, args)
	local paths = get_selected_paths()
	if #paths == 0 then
		micro.InfoBar():Error("Nothing to cut")
		return
	end
	clipboard.paths = paths
	clipboard.mode = "cut"
	micro.InfoBar():Message("Cut " .. #paths .. " item(s)")
end

function paste_clipboard(bp, args)
	if clipboard.mode == nil or #clipboard.paths == 0 then
		micro.InfoBar():Error("Nothing in clipboard")
		return
	end

	-- Determine target directory
	local target_dir = current_dir
	local y = get_safe_y()
	if y > 0 and not scanlist_is_empty() then
		if scanlist[y].dirmsg ~= "" then
			target_dir = scanlist[y].abspath
		else
			target_dir = filepath.Dir(scanlist[y].abspath)
		end
	end

	for _, src in ipairs(clipboard.paths) do
		local name = get_basename(src)
		local dest = filepath.Join(target_dir, name)

		if clipboard.mode == "copy" then
			-- Use cp command for recursive copy
			local _, err = shell.RunCommand('cp -r "' .. src .. '" "' .. dest .. '"')
			if err ~= nil then
				micro.InfoBar():Error("Copy failed: ", tostring(err))
				return
			end
		elseif clipboard.mode == "cut" then
			local err = os.Rename(src, dest)
			if err ~= nil then
				-- Cross-device move: cp then rm
				local _, cp_err = shell.RunCommand('cp -r "' .. src .. '" "' .. dest .. '"')
				if cp_err ~= nil then
					micro.InfoBar():Error("Move failed: ", tostring(cp_err))
					return
				end
				os.RemoveAll(src)
			end
		end
	end

	local count = #clipboard.paths
	local action = clipboard.mode == "copy" and "Pasted" or "Moved"
	if clipboard.mode == "cut" then
		clipboard = { paths = {}, mode = nil }
	end
	clear_selection()

	-- Refresh the tree
	update_current_dir(current_dir)
	micro.InfoBar():Message(action .. " " .. count .. " item(s)")
end

-- =============================================================================
-- BOOKMARKS
-- =============================================================================

local bookmarks_file = ""

local function get_bookmarks_path()
	if bookmarks_file == "" then
		local config_dir = config.ConfigDir
		bookmarks_file = filepath.Join(config_dir, "filemanager-bookmarks.txt")
	end
	return bookmarks_file
end

local function load_bookmarks()
	bookmarks = {}
	local path = get_bookmarks_path()
	if not path_exists(path) then return end
	local f, err = os.Open(path)
	if f == nil then return end
	-- Read line by line using a simple approach
	local content_bytes, _ = import("io/ioutil").ReadAll(f)
	f:Close()
	if content_bytes == nil then return end
	local content = tostring(content_bytes)
	for line in string.gmatch(content, "([^\r\n]+)") do
		if #line > 0 then
			bookmarks[#bookmarks + 1] = line
		end
	end
end

local function save_bookmarks()
	local path = get_bookmarks_path()
	local content = table.concat(bookmarks, "\n")
	local f, err = os.Create(path)
	if f == nil then
		micro.InfoBar():Error("Can't save bookmarks: ", tostring(err))
		return
	end
	f:Write(content)
	f:Close()
end

function bookmark_current_dir(bp, args)
	load_bookmarks()
	-- Check if already bookmarked
	for _, bm in ipairs(bookmarks) do
		if bm == current_dir then
			micro.InfoBar():Message("Already bookmarked: ", current_dir)
			return
		end
	end
	bookmarks[#bookmarks + 1] = current_dir
	save_bookmarks()
	micro.InfoBar():Message("Bookmarked: ", current_dir)
end

function open_bookmarks(bp, args)
	load_bookmarks()
	if #bookmarks == 0 then
		micro.InfoBar():Message("No bookmarks saved")
		return
	end
	-- Display bookmarks in the info bar as a numbered list
	local msg = "Bookmarks: "
	for i, bm in ipairs(bookmarks) do
		msg = msg .. i .. "=" .. bm .. " "
	end
	micro.InfoBar():Message(msg)
	-- TODO: When micro supports interactive selection, use that
end

-- =============================================================================
-- SEARCH
-- =============================================================================

local function do_search(query)
	search_matches = {}
	search_query = query
	if query == "" then return end

	local lower_query = string.lower(query)
	for i = 1, #scanlist do
		local name = string.lower(get_basename(scanlist[i].abspath))
		if string.find(name, lower_query, 1, true) then
			search_matches[#search_matches + 1] = i
		end
	end
	search_index = 0
end

local function jump_to_next_match()
	if #search_matches == 0 then
		micro.InfoBar():Message("No matches")
		return
	end
	search_index = search_index + 1
	if search_index > #search_matches then
		search_index = 1
	end
	local idx = search_matches[search_index]
	tree_view.Cursor.Loc.Y = idx + 2
	select_line()
	micro.InfoBar():Message("Match " .. search_index .. "/" .. #search_matches)
end

local function jump_to_prev_match()
	if #search_matches == 0 then
		micro.InfoBar():Message("No matches")
		return
	end
	search_index = search_index - 1
	if search_index < 1 then
		search_index = #search_matches
	end
	local idx = search_matches[search_index]
	tree_view.Cursor.Loc.Y = idx + 2
	select_line()
	micro.InfoBar():Message("Match " .. search_index .. "/" .. #search_matches)
end

-- =============================================================================
-- TREE OPEN / CLOSE / TOGGLE
-- =============================================================================

local function open_tree()
	local wd = get_working_dir()
	if wd == nil or wd == "" then wd = "." end
	current_dir = wd

	local buf = buffer.NewBuffer("", "filemanager")
	micro.CurPane():VSplitIndex(buf, false)
	tree_view = micro.CurPane()

	local tw = config.GetGlobalOption("filemanager.treewidth") or 30

	-- Set buffer type to scratch/readonly before anything else
	tree_view.Buf.Type.Kind = 2
	tree_view.Buf.Type.Readonly = true
	tree_view.Buf.Type.Scratch = true

	-- Set buffer-local display settings
	tree_view.Buf.Settings["softwrap"] = true
	tree_view.Buf.Settings["ruler"] = false
	tree_view.Buf.Settings["autosave"] = false
	tree_view.Buf.Settings["statusline"] = false
	tree_view.Buf.Settings["scrollbar"] = false

	-- Resize tree to configured width
	tree_view:ResizePane(tw)

	update_current_dir(wd)
end

local function close_tree()
	if tree_view ~= nil then
		tree_view:Quit()
		tree_view = nil
	end
end

function toggle_tree(bp, args)
	if tree_view == nil then
		open_tree()
	else
		close_tree()
	end
end

-- =============================================================================
-- NAVIGATION HELPERS
-- =============================================================================

function goto_parent_dir()
	if tree_view == nil or micro.CurPane() ~= tree_view or scanlist_is_empty() then return end
	local cur_y = get_safe_y()
	if cur_y > 0 then
		tree_view.Cursor:UpN(cur_y - scanlist[cur_y].owner)
		select_line()
	end
end

function goto_prev_dir()
	if tree_view == nil or micro.CurPane() ~= tree_view or scanlist_is_empty() then return end
	local cur_y = get_safe_y()
	if cur_y ~= 0 then
		local move_count = 0
		for i = cur_y - 1, 1, -1 do
			move_count = move_count + 1
			if scanlist[i].dirmsg ~= "" then
				tree_view.Cursor:UpN(move_count)
				select_line()
				break
			end
		end
	end
end

function goto_next_dir()
	if tree_view == nil or micro.CurPane() ~= tree_view or scanlist_is_empty() then return end
	local cur_y = get_safe_y()
	local move_count = 0
	if cur_y == 0 then
		cur_y = 1
		move_count = 1
	end
	if cur_y < #scanlist then
		for i = cur_y + 1, #scanlist do
			move_count = move_count + 1
			if scanlist[i].dirmsg ~= "" then
				tree_view.Cursor:DownN(move_count)
				select_line()
				break
			end
		end
	end
end

-- Follow active file in tree
local function follow_active_file(bp)
	if tree_view == nil or bp == tree_view then return end
	if not config.GetGlobalOption("filemanager.followactive") then return end

	local file_path = bp.Buf.AbsPath
	if file_path == nil or file_path == "" then return end

	-- Check if file is within current_dir
	local prefix = current_dir .. "/"
	if string.sub(file_path, 1, #prefix) ~= prefix then
		-- File is outside current tree dir — navigate to its parent
		local dir = filepath.Dir(file_path)
		if dir ~= current_dir then
			update_current_dir(dir)
		end
	end

	-- Try to find and highlight the file in scanlist
	for i = 1, #scanlist do
		if scanlist[i].abspath == file_path then
			tree_view.Cursor.Loc.Y = i + 2
			tree_view.Cursor:Relocate()
			tree_view.Cursor:SelectLine()
			return
		end
	end
end

-- =============================================================================
-- EVENT CALLBACKS
-- =============================================================================

local function is_tree(bp)
	return bp == tree_view
end

local function false_if_tree(bp)
	if is_tree(bp) then return false end
end

local function selectline_if_tree(bp)
	if is_tree(bp) then select_line() end
end

local function aftermove_if_tree(bp)
	if is_tree(bp) then
		if tree_view.Cursor.Loc.Y < 2 then
			tree_view.Cursor:DownN(2 - tree_view.Cursor.Loc.Y)
		end
		select_line()
	end
end

-- Close
function preQuit(bp)
	if is_tree(bp) then
		close_tree()
		return false
	end
	-- If quitting the last editor pane, close the tree too so micro exits
	if tree_view ~= nil then
		local tab = micro.CurTab()
		if tab ~= nil and #tab.Panes <= 2 then
			close_tree()
		end
	end
end

function preQuitAll(bp)
	close_tree()
end

-- Cursor movement
function preCursorDown(bp)
	if is_tree(bp) then
		tree_view.Cursor:Down()
		select_line()
		return false
	end
end

function onCursorUp(bp)
	selectline_if_tree(bp)
end

function preCursorUp(bp)
	if is_tree(bp) then
		if tree_view.Cursor.Loc.Y == 2 then
			return false
		end
	end
end

-- Left = compress, Right = uncompress
function preCursorLeft(bp)
	if is_tree(bp) then
		compress_target(get_safe_y(), false)
		return false
	end
end

function preCursorRight(bp)
	if is_tree(bp) then
		uncompress_target(get_safe_y())
		return false
	end
end

-- Page up/down
function onCursorPageUp(bp)
	aftermove_if_tree(bp)
end

function onCursorPageDown(bp)
	selectline_if_tree(bp)
end

function onCursorStart(bp)
	aftermove_if_tree(bp)
end

function onCursorEnd(bp)
	selectline_if_tree(bp)
end

-- Split navigation
function onNextSplit(bp)
	selectline_if_tree(bp)
end

function onPreviousSplit(bp)
	selectline_if_tree(bp)
end

-- Tab = open
local tab_pressed = false

function preIndentSelection(bp)
	if is_tree(bp) then
		tab_pressed = true
		try_open_at_y(tree_view.Cursor.Loc.Y)
		return false
	end
end

function preInsertTab(bp)
	if tab_pressed then
		tab_pressed = false
		return false
	end
end

-- Mouse handling
local last_mouse_y = -1

function preMousePress(bp, event)
	if is_tree(bp) then
		return true
	end
end

function onMousePress(bp, event)
	if is_tree(bp) then
		local y = tree_view.Cursor.Loc.Y
		if y < 2 then
			tree_view.Cursor.Loc.Y = 2
			select_line()
			last_mouse_y = -1
			return true
		end

		if y == last_mouse_y then
			-- Second click on same line: open
			local save_y = y
			try_open_at_y(y)
			-- Restore highlight after pane switch
			tree_view.Cursor.Loc.Y = save_y
			tree_view.Cursor:Relocate()
			tree_view.Cursor:SelectLine()
			last_mouse_y = -1
		else
			-- First click: just highlight
			select_line()
			last_mouse_y = y
		end
		return true
	end
end

-- ShiftUp = parent dir
function preSelectUp(bp)
	if is_tree(bp) then
		goto_parent_dir()
		return false
	end
end

-- Paragraph nav = prev/next dir
function preParagraphPrevious(bp)
	if is_tree(bp) then
		goto_prev_dir()
		return false
	end
end

function preParagraphNext(bp)
	if is_tree(bp) then
		goto_next_dir()
		return false
	end
end

-- Find
function preFind(bp)
	if is_tree(bp) then
		tree_view.Cursor:ResetSelection()
	end
end

function onFind(bp)
	selectline_if_tree(bp)
end

function onFindNext(bp)
	selectline_if_tree(bp)
end

function onFindPrevious(bp)
	selectline_if_tree(bp)
end

-- Jump line
function onJumpLine(bp)
	aftermove_if_tree(bp)
end

-- CD detection
local precmd_dir = ""

function preCommandMode(bp)
	precmd_dir = get_working_dir()
end

function onCommandMode(bp)
	local new_dir = get_working_dir()
	if tree_view ~= nil and new_dir ~= precmd_dir and new_dir ~= current_dir then
		update_current_dir(new_dir)
	end
end

-- Auto-refresh on save
function onSave(bp)
	if tree_view ~= nil and bp ~= tree_view then

		refresh_and_select()
	end
end

-- Follow active file on pane switch
function onSetActive(bp)
	if tree_view ~= nil and bp ~= tree_view then
		follow_active_file(bp)
	end
end

-- Vim-style keybinding handler via rune insertion
function preRune(bp, r)
	if not is_tree(bp) then return end
	if not config.GetGlobalOption("filemanager.vimbindings") then return end

	local char = r

	if char == "j" then
		-- Down
		tree_view.Cursor:Down()
		select_line()
		return false
	elseif char == "k" then
		-- Up
		if tree_view.Cursor.Loc.Y > 2 then
			tree_view.Cursor:Up()
			select_line()
		end
		return false
	elseif char == "h" then
		-- Collapse / parent
		compress_target(get_safe_y(), false)
		return false
	elseif char == "l" then
		-- Expand / open
		local y = get_safe_y()
		if y > 0 and not scanlist_is_empty() and scanlist[y].dirmsg == "+" then
			uncompress_target(y)
		else
			try_open_at_y(tree_view.Cursor.Loc.Y)
		end
		return false
	elseif char == "o" then
		-- Open file
		try_open_at_y(tree_view.Cursor.Loc.Y)
		return false
	elseif char == "O" then
		-- Open in new tab
		try_open_in_tab(tree_view.Cursor.Loc.Y)
		return false
	elseif char == "q" then
		-- Close tree
		close_tree()
		return false
	elseif char == "a" then
		-- New file prompt
		micro.InfoBar():Prompt("New file: ", "", "FileNew", nil, function(name, cancelled)
			if not cancelled and name ~= "" then
				create_filedir(name, false)
			end
		end)
		return false
	elseif char == "A" then
		-- New dir prompt
		micro.InfoBar():Prompt("New directory: ", "", "DirNew", nil, function(name, cancelled)
			if not cancelled and name ~= "" then
				create_filedir(name, true)
			end
		end)
		return false
	elseif char == "r" then
		-- Rename prompt
		local y = get_safe_y()
		if y > 0 and not scanlist_is_empty() then
			local old_name = get_basename(scanlist[y].abspath)
			micro.InfoBar():Prompt("Rename to: ", old_name, "Rename", nil, function(new_name, cancelled)
				if not cancelled and new_name ~= "" and new_name ~= old_name then
					local old_path = scanlist[y].abspath
					local new_path = dirname_and_join(old_path, new_name)
					local err = os.Rename(old_path, new_path)
					if err ~= nil then
						micro.InfoBar():Error("Rename failed: ", tostring(err))
						return
					end
					scanlist[y].abspath = new_path
					refresh_and_select()
					micro.InfoBar():Message("Renamed to: ", new_name)
				end
			end)
		end
		return false
	elseif char == "d" then
		-- Delete (trash)
		prompt_delete_at_cursor(bp, nil)
		return false
	elseif char == "D" then
		-- Delete (permanent)
		force_delete_at_cursor(bp, nil)
		return false
	elseif char == "y" then
		-- Copy (yank)
		copy_at_cursor(bp, nil)
		return false
	elseif char == "p" then
		-- Paste
		paste_clipboard(bp, nil)
		return false
	elseif char == "x" then
		-- Cut
		cut_at_cursor(bp, nil)
		return false
	elseif char == " " then
		-- Toggle select
		local y = get_safe_y()
		if y > 0 and not scanlist_is_empty() then
			toggle_select(scanlist[y].abspath)
			tree_view.Cursor:Down()
			refresh_and_select()
		end
		return false
	elseif char == "/" then
		-- Search
		micro.InfoBar():Prompt("Search: ", "", "Search", nil, function(query, cancelled)
			if not cancelled then
				do_search(query)
				jump_to_next_match()
			end
		end)
		return false
	elseif char == "n" then
		-- Next search match
		jump_to_next_match()
		return false
	elseif char == "N" then
		-- Prev search match
		jump_to_prev_match()
		return false
	elseif char == "m" then
		-- Bookmark
		bookmark_current_dir(bp, nil)
		return false
	elseif char == "R" then
		-- Refresh

		update_current_dir(current_dir)
		return false
	elseif char == "." then
		-- Toggle dotfiles
		local current = config.GetGlobalOption("filemanager.showdotfiles")
		config.SetGlobalOption("filemanager.showdotfiles", not current)
		update_current_dir(current_dir)
		return false
	end

	-- Block all other rune insertion in tree
	return false
end

-- =============================================================================
-- BLOCK UNWANTED ACTIONS IN TREE
-- =============================================================================

function preStartOfLine(bp) return false_if_tree(bp) end
function preEndOfLine(bp) return false_if_tree(bp) end
function preMoveLinesDown(bp) return false_if_tree(bp) end
function preMoveLinesUp(bp) return false_if_tree(bp) end
function preWordRight(bp) return false_if_tree(bp) end
function preWordLeft(bp) return false_if_tree(bp) end
function preSelectDown(bp) return false_if_tree(bp) end
function preSelectLeft(bp) return false_if_tree(bp) end
function preSelectRight(bp) return false_if_tree(bp) end
function preSelectWordRight(bp) return false_if_tree(bp) end
function preSelectWordLeft(bp) return false_if_tree(bp) end
function preSelectToStartOfLine(bp) return false_if_tree(bp) end
function preSelectToEndOfLine(bp) return false_if_tree(bp) end
function preSelectToStart(bp) return false_if_tree(bp) end
function preSelectToEnd(bp) return false_if_tree(bp) end
function preDeleteWordLeft(bp) return false_if_tree(bp) end
function preDeleteWordRight(bp) return false_if_tree(bp) end
function preOutdentSelection(bp) return false_if_tree(bp) end
function preOutdentLine(bp) return false_if_tree(bp) end
function preSave(bp) return false_if_tree(bp) end
function preCut(bp) return false_if_tree(bp) end
function preCutLine(bp) return false_if_tree(bp) end
function preDuplicateLine(bp) return false_if_tree(bp) end
function prePaste(bp) return false_if_tree(bp) end
function prePastePrimary(bp) return false_if_tree(bp) end
function preMouseMultiCursor(bp) return false_if_tree(bp) end
function preSpawnMultiCursor(bp) return false_if_tree(bp) end
function preSelectAll(bp) return false_if_tree(bp) end
