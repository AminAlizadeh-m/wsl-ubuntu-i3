# i3 on WSL (Ubuntu 26.04)

Scripts to install the [i3](https://i3wm.org) window manager in WSL2 and run it with a GUI.

WSLg (the GUI support built into WSL) manages app windows itself, so i3 can't take over the Windows desktop directly. These scripts give you three ways to run it instead:

| Method | Script | Needs on Windows | Feel |
| --- | --- | --- | --- |
| Nested window via WSLg | `start-i3-wslg.sh` | Nothing | i3 in a resizable window. Easiest to start with. |
| Windows X server | `start-i3-windows-xserver.sh` | VcXsrv or X410 | Full screen |
| Remote Desktop | `setup-xrdp.sh` | Nothing (uses `mstsc`) | Full desktop. Usually the smoothest for daily use. |

> These scripts have not yet been tested on a real WSL install. Please report any problems.

## Requirements

- Windows 10/11 with WSL2 and an Ubuntu 26.04 distro
- An up-to-date WSL. In PowerShell: `wsl --update`, then `wsl --shutdown`

## Quick start

In your WSL Ubuntu terminal:

```bash
cd ~/Downloads/i3-wsl-installer
chmod +x *.sh
./i3-wsl.sh
```

`i3-wsl.sh` shows a menu where you pick a method. If i3 isn't installed yet, it runs the installer first. You can also skip the menu and name the method directly:

```bash
./i3-wsl.sh install              # install i3 only
./i3-wsl.sh wslg [auto|full|WxH] [--monitor N|largest]   # option 1, e.g. ./i3-wsl.sh wslg full --monitor 2
./i3-wsl.sh xserver [DISP]       # option 2
./i3-wsl.sh xrdp [PORT]          # option 3
./i3-wsl.sh zsh                  # zsh + dark theme (see below)
./i3-wsl.sh theme [NAME]         # switch colour theme (see below)
./i3-wsl.sh polybar [OPTIONS]    # nicer i3: polybar, autotiling, picom
./i3-wsl.sh uninstall [--yes]    # remove everything
```

The sections below describe each method and the script that `i3-wsl.sh` calls for it. You can also run those scripts directly.

## Install

```bash
./install-i3.sh
```

This installs i3, i3status, i3lock, dmenu, rofi, Xephyr, xterm, feh and fonts. It also creates `~/.config/i3/config` from the stock config, so i3's first-run setup wizard doesn't appear. An existing config is left untouched.

## Option 1: i3 in a window (WSLg)

```bash
./start-i3-wslg.sh                 # window at 90% of your primary monitor (default)
./start-i3-wslg.sh full            # fullscreen on your primary monitor
./start-i3-wslg.sh 2560x1440       # exact size
./start-i3-wslg.sh full 2          # fullscreen on display number :2
./start-i3-wslg.sh --monitors      # list your monitors
./start-i3-wslg.sh full --monitor 2        # fullscreen on monitor 2
./start-i3-wslg.sh full --monitor largest  # fullscreen on your biggest monitor
```

- **Multiple monitors:** i3's screen size is set when it starts, from your primary monitor unless you choose with `--monitor`. If you drag the window to a monitor with a different size, **maximize it there** (double-click the title bar) and i3 resizes to fit. Fullscreen windows can't be resized that way, so for those, quit i3 (Alt+Shift+e) and start it again with `--monitor`.

- The monitor size comes from WSLg (`xrandr`). You can also resize or maximize the window afterwards, and i3 adapts to the new size.
- Press **Ctrl+Shift** inside the window to grab the keyboard so Alt shortcuts go to i3. Press it again to release.
- Closing the window or exiting i3 (Alt+Shift+e) stops everything.

## Option 2: full screen with a Windows X server

1. On Windows, start your X server:
   - **VcXsrv (XLaunch):** choose "One large window" or "Fullscreen", display number `0`, and tick **Disable access control**.
   - **X410:** use "Floating Desktop" mode and enable **Allow Public Access**.
2. Allow it through Windows Firewall when prompted, including on Public networks.
3. In WSL:

   ```bash
   ./start-i3-windows-xserver.sh      # display 0
   ./start-i3-windows-xserver.sh 1    # another display number
   ```

The script finds the Windows host address automatically, for both the NAT and mirrored WSL network modes.

## Option 3: full desktop over Remote Desktop (xrdp)

```bash
./setup-xrdp.sh          # listens on port 3390
./setup-xrdp.sh 3395     # custom port
```

Then on Windows:

```text
mstsc /v:localhost:3390
```

Log in with your Linux username and password, and choose the **Xorg** session.

- It uses port 3390 so it doesn't clash with Windows' own Remote Desktop on 3389.
- It needs systemd, which Ubuntu on WSL turns on by default. If it's off, add this to `/etc/wsl.conf` and run `wsl --shutdown`:

  ```ini
  [boot]
  systemd=true
  ```

- If `localhost` doesn't connect, use the WSL IP address that the script prints.
- The script writes `~/.xsession` so that RDP logins start i3.

## Zsh and dark theme

```bash
./setup-zsh-dark.sh
```

Run this after i3 is installed (or pick **Zsh + dark theme** from the `i3-wsl.sh` menu). It sets up:

- **git**
- **zsh** as your login shell, with [Oh My Zsh](https://ohmyz.sh), the `robbyrussell` theme and these plugins:
  - **git:** short aliases (`gst`, `gco`, `gp` and more) and git completion
  - **zsh-autosuggestions:** a grey suggestion from your history as you type. Press Right arrow or End to accept it.
  - **zsh-syntax-highlighting:** commands turn green when valid and red when not.
- **Alacritty** as the Alt+Enter terminal, in dark colours. Xephyr and xrdp have no GPU, so it runs with software rendering, and falls back to a dark-themed xterm if it can't start
- **Dark i3:** window borders, a bar at the top, small gaps between windows and the JetBrains Mono font (if available), in the Tokyo Night theme. Switch with `set-theme.sh` (below).
- **Dark rofi** launcher (Alt+d) and dark GTK apps

Then press **Alt+Shift+r** in i3 to load it.

- Your zsh config is [config/zshrc](config/zshrc). The script copies it to `~/.zshrc`, so edit that file in the repo to change it everywhere. It also loads nvm and Go if you have them installed.
- Oh My Zsh and the two extra plugins are downloaded with git from GitHub. Running the script again updates the plugins. Oh My Zsh updates itself.
- `chsh` asks for your Linux password. Changing the login shell also changes what Windows Terminal's Ubuntu tab and `wsl` open, so reopen them to get zsh.
- Files it replaces are backed up once as `<file>.pre-zsh-dark`: `~/.zshrc`, `~/.Xresources`, `~/.config/i3/config`, and the Alacritty and rofi configs.
- It's safe to run again. Its i3 settings live between `# >>> wsl-dark-theme >>>` markers and are replaced, not duplicated. Put your own i3 changes outside those markers.

## Colour themes

```bash
./set-theme.sh               # list themes and show the current one
./set-theme.sh catppuccin    # apply a theme
```

| Theme | Look |
| --- | --- |
| `catppuccin` | Soft pastels on dark blue-grey (Catppuccin Mocha) |
| `gruvbox` | Warm retro browns and oranges |
| `nord` | Cool, muted blue-grey |
| `tokyonight` | Dark navy with blue and purple (default) |
| `dracula` | Dark with vivid purple and pink |

One command recolours i3 window borders, the bar, i3status text, Alacritty, xterm and the rofi launcher. If i3 is running, it restarts i3 to apply the colours (your windows stay open). Open Alacritty windows update by themselves.

You can also pick **Change colour theme** from the `i3-wsl.sh` menu. Running `setup-zsh-dark.sh` again keeps whichever theme you chose.

## Nicer i3: polybar, autotiling, picom

```bash
./setup-polybar.sh                # everything
./setup-polybar.sh --no-polybar   # keep the i3 bar, add autotiling and picom
./setup-polybar.sh --no-picom     # without the compositor
```

Run it again with different options whenever you change your mind. For example, `--no-polybar` switches back to the i3 bar (in your theme colours) and keeps autotiling and picom.

- **polybar** replaces the i3 bar. It shows workspaces, the active window title, CPU, RAM, disk and the clock, in your theme's colours. `set-theme.sh` recolours it too.
- **autotiling:** new windows alternate between side-by-side and stacked, so you don't need to choose a split direction.
- **picom:** soft shadows, fading and rounded corners. There's no graphics card acceleration in the i3 window or over RDP, so it uses light CPU-only effects. If windows feel slow or turn black, run `pkill picom`, or set up again with `--no-picom`.
- **Wallpaper:** copy any image to `~/.wallpaper` and press Alt+Shift+r.

Press Alt+Shift+r in i3 after the first run to start them. Uninstall removes all of this and brings back the i3 bar, keeping your theme.

## Uninstall

```bash
./uninstall-i3.sh          # asks before each step
./uninstall-i3.sh --yes    # no questions
```

You can also pick **Uninstall** from the `i3-wsl.sh` menu. The script:

- Removes polybar, picom and autotiling, and brings back the i3 bar
- Undoes the zsh + dark theme setup: switches your login shell back to bash first, restores the `.pre-zsh-dark` backups, removes Oh My Zsh (only if this project installed it), and removes zsh and Alacritty. It keeps git, since other things use it.
- Stops and removes xrdp, if it was installed
- Removes i3, i3status, i3lock, dmenu, rofi and Xephyr
- Asks separately before removing general X tools (xterm, feh, x11-apps and others), since other Linux GUI apps may use them
- Runs `apt-get autoremove`, which lists what it will remove and asks first (unless you used `--yes`)
- Deletes `~/.xsession` only if it is still the version `setup-xrdp.sh` wrote
- Moves `~/.config/i3` to a timestamped backup rather than deleting it

It never removes `iproute2` or `fonts-dejavu-core`, since other software relies on them.

### Removing GlazeWM

Earlier versions of this project could install GlazeWM, a tiling window manager for Windows. Its Alt shortcuts clash with i3. For example, it can leave Alt "stuck" so that every Enter opens a new terminal. To remove it, run this from WSL:

```bash
./uninstall-glazewm.sh
```

It undoes only what the old `setup-glazewm.sh` did, and skips anything that never happened. It removes the GlazeWM config file the script wrote (restoring yours if one was backed up), quits GlazeWM if it's running, and uninstalls it with winget if it was installed. If GlazeWM was never installed, it says there's nothing to do.

## Keys

The modifier is **Alt**, not the Win key, because Windows takes most Win-key shortcuts before Linux sees them.

| Keys | Action |
| --- | --- |
| Alt+Enter | Terminal |
| Alt+d | App launcher (rofi) |
| Alt+Shift+q | Close window |
| Alt+1 … Alt+0 | Switch workspace |
| Alt+Shift+1 … | Move window to workspace |
| Alt+Shift+r | Restart i3 (reload config) |
| Alt+Shift+e | Exit i3 |

Edit `~/.config/i3/config` to customise. To use the Win key anyway, change `set $mod Mod1` to `set $mod Mod4`. This works best with the xrdp option.

## Troubleshooting

- **"DISPLAY is not set"** (option 1): WSLg isn't running. Run `wsl --update` and `wsl --shutdown` in PowerShell, then reopen Ubuntu.
- **Xephyr fails to start:** some WSL versions mount `/tmp/.X11-unix` read-only. The script tries to remount it as writable using sudo. Check `/tmp/xephyr-1.log` for details.
- **Every Enter opens a terminal, or every d opens the launcher:** the i3 window thinks Alt is still held, usually after Alt+Tab to a Windows app. `start-i3-wslg.sh` releases the modifier keys when i3 starts and every time the i3 window gets focus back. If it still happens, press Alt once on its own, or run `fixkeys` in a zsh terminal (from `config/zshrc`). If your keyboard layout isn't detected correctly, set it with `I3_KB_LAYOUT=de ./start-i3-wslg.sh`, for example.
- **"Display :1 is already in use":** pass another display number, e.g. `./start-i3-wslg.sh auto 2`.
- **"Cannot reach an X server"** (option 2): make sure the Windows X server is running, access control is disabled, and the firewall allows it on Public networks.
- **Black screen over RDP:** make sure `~/.xsession` exists and is executable, and that no other i3 session for your user is already running.

## License

[MIT](LICENSE)
