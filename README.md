# Filemanager Plugin

A file tree sidebar for the [Micro](https://micro-editor.github.io/) text editor. Browse, open, create, rename, copy, move, and delete files without leaving the editor.

**Requires Micro v2.0.0+**

![Example picture](./example.jpg?raw=true "Example")

## Installation

```bash
git clone https://github.com/HopperShell/filemanager-plugin ~/.config/micro/plug/filemanager
```

Then restart Micro. Open the tree with `Ctrl+E` → `tree`.

## Usage

The top line shows the current directory. `..` navigates to the parent directory.

Directories show `+` when collapsed and `-` when expanded, with a trailing `/`.

Double-click a file to open it in the editor pane. Double-click a directory to enter it.

### Options

| Option | Purpose | Default |
|:---|:---|:---|
| `filemanager.showdotfiles` | Show hidden dotfiles | `true` |
| `filemanager.compressparent` | Collapse parent dir when pressing left on a file | `true` |
| `filemanager.foldersfirst` | Sort folders above files | `true` |
| `filemanager.openonstart` | Auto-open tree when Micro starts | `false` |
| `filemanager.treewidth` | Tree pane width in columns | `30` |
| `filemanager.followactive` | Tree follows the active editor file | `true` |
| `filemanager.showsize` | Show file sizes | `false` |
| `filemanager.showperms` | Show file permissions | `false` |
| `filemanager.trashdefault` | Delete to trash instead of permanent | `true` |
| `filemanager.vimbindings` | Enable vim-style keybindings in tree | `true` |

### Commands

| Command | Description |
|:---|:---|
| `tree` | Toggle tree open/closed |
| `rm` | Delete file/dir (trash or permanent based on config) |
| `rm!` | Permanently delete file/dir |
| `rename <name>` | Rename file/dir at cursor |
| `touch <name>` | Create a new file |
| `mkdir <name>` | Create a new directory |
| `copy` | Copy selected file(s) to clipboard |
| `cut` | Cut selected file(s) to clipboard |
| `paste` | Paste clipboard to current directory |
| `bookmark` | Bookmark current directory |
| `bookmarks` | List bookmarks |

### Keybindings

#### Vim-style (when tree is focused, enabled by default)

| Key | Action |
|:---|:---|
| `j` / `k` | Move down / up |
| `h` | Collapse directory or go to parent |
| `l` | Expand directory or open file |
| `o` / `Enter` | Open file in editor |
| `O` | Open file in new split |
| `q` | Close tree |
| `a` | Create new file (prompts for name) |
| `A` | Create new directory (prompts for name) |
| `r` | Rename (prompts for new name) |
| `d` | Delete (trash) |
| `D` | Delete (permanent) |
| `y` | Copy file |
| `x` | Cut file |
| `p` | Paste |
| `Space` | Toggle multi-select |
| `/` | Search files |
| `n` / `N` | Next / previous search match |
| `m` | Bookmark current directory |
| `R` | Refresh tree |
| `.` | Toggle dotfiles |

#### Traditional (always active)

| Key | Action |
|:---|:---|
| `↑` / `↓` | Move up / down |
| `←` | Collapse directory |
| `→` | Expand directory |
| `Tab` | Open file |
| `Shift+↑` | Go to parent directory |
| `Alt+Shift+{` | Jump to previous directory |
| `Alt+Shift+}` | Jump to next directory |
| `Ctrl+W` | Switch between tree and editor pane |

#### Mouse

| Action | Result |
|:---|:---|
| Single click | Select/highlight file |
| Double click | Open file or enter directory |

### Tips

- `Ctrl+W` switches focus between the tree and editor panes.
- Multi-select files with `Space`, then use `y`/`x`/`d` to act on all selected.
- The tree auto-refreshes when you save a file or switch panes.
