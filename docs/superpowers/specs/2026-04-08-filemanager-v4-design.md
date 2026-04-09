# Filemanager Plugin v4.0 — Micro v2 Port & Modernization

## Overview

Full rewrite of the filemanager plugin for Micro v2.0.15+. Hybrid approach: preserve the proven tree data model (scanlist/ownership) while restructuring everything else into a modular architecture. Adds first-class mouse support, git status indicators, file copy/move, multi-select, auto-refresh, search, bookmarks, file preview, trash-based deletion, and dual vim/traditional keybindings.

## Module Architecture

```
filemanager-plugin/
├── filemanager.lua      # Entry point: init(), command registration, event routing
├── tree.lua             # Tree data model: scanlist, expand/collapse, ownership tracking
├── render.lua           # Rendering: buffer content, highlighting, cursor management
├── fileops.lua          # File ops: create, delete, rename, copy, move, trash
├── git.lua              # Git: status detection, ignore filtering, status indicators
├── mouse.lua            # Mouse: click nav, drag resize, scroll, context awareness
├── navigation.lua       # Keyboard: vim + traditional bindings, multi-select, search
├── config.lua           # Options registration, defaults, user preferences
├── util.lua             # Shared helpers: path ops, string utils, OS detection
├── syntax.yaml          # Syntax highlighting (expanded for git status)
└── repo.json            # Plugin metadata (updated for v2)
```

**Data flow:** Events → `filemanager.lua` → route to module → `tree.lua` updates model → `render.lua` redraws buffer.

## Micro v2 API Migration

Key API changes from v1:
- `CurView()` → `micro.CurPane()` (with nil checks)
- `messenger:Error/Message/YesNoPrompt` → `micro.InfoBar():Error/Message/YNPrompt`
- `AddOption()` → `config.RegisterCommonOption("filemanager", key, default)`
- `GetOption()` → `config.GetGlobalOption("filemanager.key")`
- `MakeCommand()` → `config.MakeCommand()`
- `NewBuffer()` → `buffer.NewBuffer()`
- `tabs[curTab+1]:Resize()` → `micro.CurTab():Resize()`
- `tree_view.Buf.Cursor` → `tree_view.Cursor` (cursor on pane, not buffer)
- `ioutil.ReadDir()` → `os.ReadDir()`
- `Loc(x,y)` → `buffer.Loc(x,y)`
- View properties via `pane:GetView()` instead of direct access
- `RunShellCommand()` → `shell.ExecCommand()`

## Features

### 1. Core Tree (ported from v3)
- Expandable/collapsible directory tree with `+`/`-`/`/` indicators
- Scanlist flat data structure with ownership tracking for indentation
- Current directory path at top, `..` for parent navigation
- Read-only scratch buffer for the tree pane
- Folders-first sorting option

### 2. Mouse Support (NEW)
- **Left click** on file → open in editor pane
- **Left click** on directory → expand/collapse
- **Left click** on `..` → go to parent
- **Double click** on file → open in new tab
- **Click + drag** on tree border → resize tree width
- **Scroll wheel** → scroll the tree
- **Right click** → context menu (if Micro supports, otherwise no-op)
- Mouse events intercepted via `preMousePress`, `onMousePress` callbacks
- Calculate clicked line from mouse Y coordinate relative to tree pane

### 3. Git Integration (ENHANCED)
- File status indicators: `M` modified, `A` added, `?` untracked, `D` deleted, `R` renamed
- Color coding via syntax rules: green=added, yellow=modified, red=deleted, grey=ignored
- Directory-level status rollup (dir shows modified if any child is modified)
- `.gitignore` filtering (existing, improved)
- Support for nested git repos
- Status refresh on tree refresh via `git status --porcelain`

### 4. File Operations (ENHANCED)
- **Create:** `touch` (file) and `mkdir` (directory) — existing
- **Rename:** `rename` with inline prompt — existing
- **Delete:** Trash by default via `mv` to `~/.Trash` (macOS) or `trash-cli` (Linux), permanent delete with `rm!` command
- **Copy:** `yy` (vim) or new `copy` command → marks file → `p` (vim) or `paste` command to paste
- **Move:** `dd` (vim cut) or `cut` command → marks file → `p`/`paste` to move
- **Bulk operations:** When multi-select is active, copy/move/delete apply to all selected

### 5. Multi-Select (NEW)
- **Toggle select:** `Space` or `Ctrl+click` to toggle individual file selection
- **Range select:** `Shift+click` or `V` then movement for range
- **Select all:** `Ctrl+a` in tree pane
- **Clear selection:** `Escape`
- Visual indicator: highlighted/marked lines for selected files
- Selected files tracked as a list of absolute paths in navigation module

### 6. Auto-Refresh (NEW)
- Tree refreshes when switching back to the tree pane (`onSetActive`)
- Tree refreshes after any file operation (save, create, delete, rename)
- Tree refreshes on `onSave` callback for any buffer
- Debounced refresh to avoid rapid re-rendering
- Preserves expand/collapse state and cursor position across refreshes

### 7. Follow Active File (NEW)
- When switching to a file in the editor, tree auto-scrolls to highlight that file
- Expands parent directories as needed to reveal the file
- Triggered on `onSetActive` and tab switch events
- Can be disabled via `filemanager.followactive` option

### 8. Search/Find (NEW)
- `/` or `Ctrl+f` in tree pane opens search prompt
- Fuzzy-matches against file names in current tree
- Results highlighted, `n`/`N` to cycle through matches
- `Enter` to jump to match, `Escape` to cancel
- Search scope: current expanded tree contents

### 9. File Preview (NEW)
- When cursor rests on a file for 500ms (configurable), show first N lines in the info bar or a temporary split
- Preview mode: `P` toggles persistent preview pane that updates as cursor moves
- Only for text files (skip binary detected via null byte check)
- Preview pane is read-only, closes when tree loses focus

### 10. Bookmarks (NEW)
- `m` to bookmark current directory, stored in `~/.config/micro/filemanager-bookmarks.json`
- `` ` `` or `B` to open bookmark list
- Quick-jump to bookmarked directories
- Bookmarks persist across sessions

### 11. File Metadata Display (NEW)
- Optional column showing file size (human-readable)
- Optional column showing permissions (rwx format)
- Toggled via `filemanager.showsize` and `filemanager.showperms` options
- Displayed after filename, right-aligned or in a fixed column

### 12. Resizable Tree (NEW)
- Default width: 30 columns
- Drag tree border with mouse to resize
- `filemanager.treewidth` option for default width
- Minimum width: 15 columns, maximum: 50% of terminal

## Keybindings

### Vim-style (when tree is focused)
| Key | Action |
|-----|--------|
| `j` / `k` | Move down / up |
| `h` | Collapse directory or go to parent |
| `l` | Expand directory or open file |
| `o` / `Enter` | Open file in editor pane |
| `O` | Open file in new tab |
| `dd` | Cut (mark for move) |
| `yy` | Copy (mark for copy) |
| `p` | Paste (copy/move to current dir) |
| `r` | Rename |
| `d` + confirm | Delete (trash) |
| `D` + confirm | Delete (permanent) |
| `a` | New file |
| `A` | New directory |
| `/` | Search |
| `n` / `N` | Next / prev search result |
| `m` | Bookmark directory |
| `` ` `` | Open bookmarks |
| `Space` | Toggle select |
| `V` | Start range select |
| `P` | Toggle preview |
| `R` | Refresh tree |
| `.` | Toggle dotfiles |
| `q` | Close tree |

### Traditional (when tree is focused)
| Key | Action |
|-----|--------|
| `Up` / `Down` | Move up / down |
| `Left` | Collapse directory |
| `Right` | Expand directory |
| `Enter` / `Tab` | Open file |
| `F2` | Rename |
| `Delete` | Delete (trash) |
| `Shift+Delete` | Delete (permanent) |
| `Ctrl+C` | Copy |
| `Ctrl+X` | Cut |
| `Ctrl+V` | Paste |
| `Ctrl+N` | New file |
| `Ctrl+Shift+N` | New directory |
| `Ctrl+F` | Search |
| `Ctrl+A` | Select all |
| `Escape` | Clear selection / cancel |
| `Shift+Up/Down` | Go to parent / next dir |

### Mouse
| Action | Result |
|--------|--------|
| Left click file | Open in editor |
| Left click dir | Expand/collapse |
| Double click file | Open in new tab |
| Ctrl+click | Toggle select |
| Shift+click | Range select |
| Scroll | Scroll tree |
| Drag border | Resize tree |

## Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `filemanager.showdotfiles` | bool | `true` | Show hidden files |
| `filemanager.showignored` | bool | `true` | Show gitignored files |
| `filemanager.compressparent` | bool | `true` | Collapse parent on left-arrow from file |
| `filemanager.foldersfirst` | bool | `true` | Sort directories above files |
| `filemanager.openonstart` | bool | `false` | Auto-open tree on startup |
| `filemanager.treewidth` | int | `30` | Default tree width in columns |
| `filemanager.followactive` | bool | `true` | Tree follows active editor file |
| `filemanager.showsize` | bool | `false` | Show file sizes |
| `filemanager.showperms` | bool | `false` | Show file permissions |
| `filemanager.previewdelay` | int | `500` | Preview delay in ms (0 to disable) |
| `filemanager.trashdefault` | bool | `true` | Use trash instead of permanent delete |
| `filemanager.vimbindings` | bool | `true` | Enable vim-style keybindings |

## Syntax Highlighting (syntax.yaml)

Extended to support git status colors:
- Default files: normal text color
- Directories: bold/blue
- Git modified: yellow
- Git added/new: green
- Git deleted: red
- Git untracked: grey/dim
- Selected files: inverse/highlight
- Symlinks: cyan
- Executable files: green+bold
- Tree structure characters (`+`, `-`, `..`): dim/comment color

## Error Handling

- All file operations wrapped in pcall for graceful error handling
- Errors displayed via `micro.InfoBar():Error()`
- File permission errors caught and reported clearly
- Git operations fail silently if not in a git repo (degrade gracefully)
- Binary file detection before preview (skip files with null bytes)
- Trash fallback: if system trash unavailable, warn and offer permanent delete

## Testing Strategy

- Manual testing against Micro v2.0.15
- Test each module independently where possible
- Test matrix: macOS (primary), Linux
- Edge cases: empty directories, deeply nested trees, symlinks, permission-denied files, large directories (1000+ files), non-git repos, Unicode filenames
