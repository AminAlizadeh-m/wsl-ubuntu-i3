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
./i3-wsl.sh install [--config]   # install i3 (--config: only update the i3 config)
./i3-wsl.sh wslg [auto|full|WxH] [--monitor N|largest] [--windows N]   # option 1, e.g. ./i3-wsl.sh wslg full --windows 2
./i3-wsl.sh xserver [DISP]       # option 2
./i3-wsl.sh xrdp [PORT]          # option 3
./i3-wsl.sh zsh                  # zsh + dark theme (see below)
./i3-wsl.sh theme [NAME]         # switch colour theme (see below)
./i3-wsl.sh polybar [OPTIONS]    # nicer i3: polybar, autotiling, picom
./i3-wsl.sh tools                # autotiling, i3lock, feh, dunst (see below)
./i3-wsl.sh chrome               # Google Chrome (also: vscode, openfortivpn, throne)
./i3-wsl.sh certs "CA NAME"      # trust a Windows CA (company network, see below)
./i3-wsl.sh uninstall [--yes]    # remove everything
```

The sections below describe each method and the script that `i3-wsl.sh` calls for it. You can also run those scripts directly.

## Install

```bash
./install-i3.sh
```

This installs i3, i3status, i3lock, dmenu, rofi, Xephyr, xterm, feh and fonts, plus the i3 config from this repo.

### The i3 config

The config lives in the repo as [config/i3/config](config/i3/config), organised in sections with comments. It's the stock i3 setup adapted for WSL, with the same keys. `install-i3.sh` sets up `~/.config/i3/` like this:

| File | What it is |
| --- | --- |
| `config` | Copy of `config/i3/config`. **Replaced on every update.** |
| `generated/theme.conf` | Colours and font, written by `set-theme.sh` |
| `generated/bar.conf` | The bar, written by `set-theme.sh` (empty when polybar is used) |
| `config.d/custom.conf` | **Your own settings.** Loaded last and never overwritten. |

- **After `git pull`,** run `./install-i3.sh --config` to update just the i3 config, without reinstalling packages. Any running i3 reloads automatically.
- **Your own changes** go in `~/.config/i3/config.d/custom.conf`, then press Alt+Shift+c to reload. You can add new shortcuts there, but not reuse a key the main config already binds, because i3 rejects duplicate bindings. To change an existing key, edit `config/i3/config` in the repo and run `./install-i3.sh --config`.
- **Upgrading from an older version** of these scripts: the first `./install-i3.sh --config` backs up your old config as `~/.config/i3/config.pre-wsl-i3` and keeps your theme. The other setup scripts do this for you automatically if needed.
- **Safety:** every script checks the config with `i3 -C` before saving. If there's an error (for example in `custom.conf`), your working config is kept and the error is shown.

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

- **One i3 over several windows:** `--windows 2` (up to 4) opens i3 as several windows that i3 treats like separate monitors, each with its own workspace. Window 1 goes on your primary monitor and the others on your other monitors, fullscreen with `full`. With fewer monitors than windows, the extra ones sit side by side. Move between them with **Alt+o** (focus the next window), **Alt+Shift+o** (send the current window there) and **Alt+Ctrl+o** (send the whole workspace).
  ```bash
  ./start-i3-wslg.sh full --windows 2   # one i3, fullscreen on each of two monitors
  ./start-i3-wslg.sh auto --windows 2   # two windows; side by side if you have one monitor
  ```
  In this mode the windows can't be resized after they open (i3's layout is fixed at start), and polybar only shows in window 1; the i3 bar shows in all of them. To make them fit your monitors again, for example after you plug in or unplug a screen or drag a window to another monitor, press **Alt+Shift+f**. It asks first, then restarts i3 with each window fullscreen on the monitor it's on now. **Open apps close** when it restarts.
- **Multiple monitors:** i3's screen size is set when it starts, from your primary monitor unless you choose with `--monitor`. If you drag the window to a monitor with a different size, press **Alt+Shift+f** in i3: the window fills the monitor it's on (fullscreen, no frame) and i3 resizes to fit. Press it again to get a normal window back, at 90% of that monitor. Maximizing the window there (double-click the title bar) works too. With `--windows`, Alt+Shift+f restarts i3 instead (see above).

- The monitor size comes from WSLg (`xrandr`). You can also resize or maximize the window afterwards, and i3 adapts to the new size.
- Press **Ctrl+Shift** inside the window to grab the keyboard so Alt shortcuts go to i3. Press it again to release.
- Closing the window or exiting i3 (Alt+Shift+e) stops everything.

### How the window looks

Before i3 draws anything, the script gives the window a normal arrow cursor (Adwaita) instead of X's big cross, fills it with your theme's background colour instead of black, and turns on smooth, anti-aliased fonts. Apps you open from i3 use the same cursor. You can change these:

```bash
./start-i3-wslg.sh full                    # no Windows title bar or frame at all
./start-i3-wslg.sh --dpi 120               # bigger text: 96 is normal, 120 = 125%, 144 = 150%
I3_TITLE="Linux" ./start-i3-wslg.sh        # window title (default "i3 (WSL)")
I3_CURSOR_SIZE=32 ./start-i3-wslg.sh       # bigger cursor; I3_CURSOR_THEME=DMZ-White picks another theme
```

The title bar and frame around the window come from Windows (WSLg), so they can't be styled; `full` removes them. Inside the window, the look comes from i3: colour themes (`./set-theme.sh`), polybar, and a wallpaper (`./install-i3-tools.sh --wallpaper IMAGE`).

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
- Files it replaces are backed up once as `<file>.pre-zsh-dark`: `~/.zshrc`, `~/.Xresources`, and the i3status, Alacritty and rofi configs. For i3 it only writes `~/.config/i3/generated/theme.conf` and `bar.conf`.
- It's safe to run again.

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

## Small tools: autotiling, i3lock, feh, dunst

```bash
./install-i3-tools.sh                           # install and set up all four
./install-i3-tools.sh --wallpaper ~/photo.jpg   # also set a wallpaper
./uninstall-i3-tools.sh                         # undo it
```

- **autotiling:** new windows alternate between side-by-side and stacked.
- **i3lock:** **Alt+Shift+x** locks the screen. Type your Linux password and press Enter to unlock.
- **feh:** sets `~/.wallpaper` as the background, and opens images (`feh picture.png`) in a floating window.
- **dunst:** desktop notifications, dark, in the top-right corner below the bar. **Alt+n** closes them and **Alt+Shift+n** brings back the last one. Test it with `notify-send "Hello" "from dunst"`. Its settings are in `~/.config/dunst/dunstrc`.

The script adds its lines to `~/.config/i3/config.d/custom.conf` between `# >>> wsl-i3-tools >>>` markers, and checks the config first. If one of those keys is already in use, it puts the file back and tells you. It starts the tools through `~/.local/bin/i3-tools` on every i3 start and restart. If you also use `setup-polybar.sh`, autotiling and the wallpaper are left to that, so nothing runs twice. It works with the standalone polybar below too.

`uninstall-i3-tools.sh` removes the lines, the launcher and the dunstrc (putting back your old one if there was one). It removes only the packages that `install-i3-tools.sh` installed, so i3lock and feh stay if `install-i3.sh` installed them.

## Standalone polybar config

[config/polybar/](config/polybar/) has a ready-made polybar config for any i3, including plain i3 from `install-i3-classic.sh`. It shows workspaces, the window title, volume, RAM, CPU, disk, Wi-Fi or Ethernet, battery, a clock and the tray icons. Modules that don't apply to your machine (no battery, no Wi-Fi) turn themselves off.

```bash
sudo apt install polybar
mkdir -p ~/.config/polybar
cp config/polybar/config.ini config/polybar/launch.sh ~/.config/polybar/
chmod +x ~/.config/polybar/launch.sh
```

Then in `~/.config/i3/config`, delete or comment out the whole `bar { ... }` block, add this line, and press Mod+Shift+r:

```
exec_always --no-startup-id ~/.config/polybar/launch.sh
```

`launch.sh` starts one bar per monitor. The colours are at the top of `config.ini`. Don't combine this with `setup-polybar.sh`, which writes its own `~/.config/polybar/config.ini`.

### Removing adi1090x/polybar-themes

If you installed [polybar-themes](https://github.com/adi1090x/polybar-themes) (for example the hack theme) and don't want it anymore:

```bash
./uninstall-polybar-themes.sh                    # repo cloned at ~/polybar-themes
./uninstall-polybar-themes.sh /path/to/the/clone # cloned somewhere else
```

It stops the theme's bars, removes the `launch.sh --<theme>` line from your i3 config (backing the file up first), deletes the themes from `~/.config/polybar` and puts back the `~/.config/polybar.old` that the theme's `setup.sh` saved. It also removes the fonts it copied into `~/.local/share/fonts`, using the clone to know which ones; your other fonts stay. It asks before deleting the clone. polybar itself stays installed.

## Apps: Chrome, VS Code, Fortinet VPN, Throne

```bash
./install-chrome.sh         # Google Chrome
./install-vscode.sh         # Visual Studio Code
./install-openfortivpn.sh   # openfortivpn, a Fortinet SSL VPN client
./install-throne.sh         # Throne, a proxy client (sing-box)
```

They're also in the `i3-wsl.sh` menu (options 9–12). Chrome and VS Code come from Google's and Microsoft's official apt repositories, so `sudo apt upgrade` keeps them up to date. In i3, open them with **Alt+d** (type `chrome` or `code`).

- **Chrome:** only available for 64-bit Intel/AMD machines; on others, use `sudo apt install chromium`. If it shows a black window, start it with `google-chrome --disable-gpu`.
- **VS Code:** the script turns off hardware acceleration in `~/.vscode/argv.json`, because the i3 window and RDP have no graphics card acceleration. If you also have VS Code on Windows, typing `code` in WSL now opens this Linux version instead.
- **Links and sign-ins open in Linux Chrome:** inside i3, links that apps open (for example VS Code's **Sign in with GitHub**) go to Chrome in i3, not to your Windows browser. That's needed for sign-ins: the browser has to hand the result back to the Linux VS Code. Outside i3, links from the WSL terminal still open on Windows. This works when i3 is started by `start-i3-wslg.sh` or `start-i3-windows-xserver.sh`, or over xrdp after running `setup-xrdp.sh` again. With no Linux Chrome or Chromium installed, links keep opening on Windows.
- **openfortivpn:** the script creates `~/.config/openfortivpn/config`, readable only by you. Fill in `host` and `username`, then connect with `sudo openfortivpn -c ~/.config/openfortivpn/config` and disconnect with Ctrl+C. Leave the password out to be asked each time. On the first connection it may print the server's certificate fingerprint; add it as `trusted-cert` once your IT team confirms it. The VPN covers WSL and the apps in i3, not Windows itself.

### Throne

`install-throne.sh` downloads the latest Throne `.deb` from its GitHub releases, checks its checksum and installs it. Running it again updates Throne. Open it in i3 with **Alt+d**, "Throne".

- **No GitHub access?** Download `Throne-<version>-debian-amd64.deb` yourself and run `./install-throne.sh --deb FILE.deb`.
- **Proxy for WSL programs:** Throne's "system proxy" switch doesn't reach WSL programs. Install with `--tun` and turn on TUN mode in Throne, or point programs at Throne's port (Settings > Inbound, 2080 by default): `export http_proxy=http://127.0.0.1:2080 https_proxy=http://127.0.0.1:2080`. After a Throne update, run `--tun` again.
- **Move your settings from another computer** (profiles, subscriptions, routing, all options):

  ```bash
  ./throne-config.sh export                 # on the old system: ~/throne-config-DATE.tar.gz
  ./throne-config.sh import FILE.tar.gz     # in WSL (or: ./install-throne.sh --config FILE.tar.gz)
  ./throne-config.sh import /mnt/c/.../Throne   # straight from a Windows Throne folder
  ```

  Export works while Throne is running. Import closes Throne and keeps your current settings as `~/.config/Throne.bak.DATE`. The backup holds your proxy servers and passwords: it's readable only by you, and git ignores it. Don't share it.
- **Uninstall:** `./uninstall-throne.sh` removes Throne completely: the package, `/opt/Throne`, `/etc/throne`, its services and launchers, and the `throne://` link handler. It asks before deleting your settings, and offers to save a backup first. `--keep-config` keeps them; `--yes` deletes them after saving a backup.

## Company network: trust a Windows CA certificate

Some company networks re-sign HTTPS traffic with their own CA. Windows trusts that CA, but Ubuntu doesn't, so `apt`, `curl`, `git` and `pip` fail with "certificate verify failed". This script copies the CA from Windows into Ubuntu:

```bash
./import-windows-certs.sh --list              # the CAs Windows trusts
./import-windows-certs.sh "Company CA name"   # clean up, then import it
```

- **The name** is the certificate's name as Windows shows it (`certmgr.msc`, "Issued To"); part of the name is enough. The certificates that issued it are imported too.
- **Cleaning first:** it removes the certificates added to Ubuntu by hand (in `/usr/local/share/ca-certificates`), turns back on any built-in ones that were turned off, and rebuilds Ubuntu's list. It asks first and keeps a backup in `~/.local/share/wsl-certs-backup`. Ubuntu's built-in certificates are never removed. Skip this with `--no-clean`, or only clean with `--clean`.
- **Chrome and VS Code** keep their own list (`~/.pki/nssdb`), so the certificate is added there too. Restart them afterwards.
- **Node and Python** use their own lists as well. Point them at Ubuntu's in `~/.zshrc`: `export NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt` and `export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt`.

It's also option 13 in the `i3-wsl.sh` menu.

## Uninstall

```bash
./uninstall-i3.sh          # asks before each step
./uninstall-i3.sh --yes    # no questions
```

You can also pick **Uninstall** from the `i3-wsl.sh` menu. The script:

- Asks whether to remove Google Chrome, VS Code and openfortivpn, if installed (your VPN settings file is kept)
- Undoes `install-i3-tools.sh` (autotiling, i3lock, feh, dunst), if it was run
- Removes polybar, picom and autotiling, and brings back the i3 bar
- Undoes the zsh + dark theme setup: switches your login shell back to bash first, restores the `.pre-zsh-dark` backups, puts i3 back to its default colours and plain bar, removes Oh My Zsh (only if this project installed it), and removes zsh and Alacritty. It keeps git, since other things use it.
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
| Alt+Shift+d | Same launcher, but runs the app as root: rofi asks for your Linux password. Switch to typing any command with Ctrl+Tab. Browsers refuse; VS Code gets its own root settings folder. |
| Alt+` | Switch to any open window by name |
| Alt+Shift+q | Close window |
| Alt+arrows / Alt+j k l ; | Move focus |
| Alt+Shift+arrows | Move window |
| Alt+1 … Alt+0 | Switch workspace |
| Alt+Shift+1 … | Move window to workspace |
| Alt+h / Alt+v | Open the next window beside / below |
| Alt+w / Alt+s / Alt+e | Tabbed / stacked / side-by-side layout |
| Alt+f | Fullscreen |
| Alt+Shift+f | Fit the i3 window to the monitor it's on / back to a normal window (option 1). With `--windows`: restart i3 fitted to your monitors (open apps close) |
| Alt+Shift+Space / Alt+Space | Float or tile a window / switch focus between them |
| Alt+Shift+- / Alt+- | Park a window in the scratchpad / bring it back |
| Alt+o / Alt+Shift+o / Alt+Ctrl+o | With `--windows`: focus the next window / move a window there / move the workspace there |
| Alt+r | Resize mode (arrows, then Enter) |
| Alt+Shift+c / Alt+Shift+r | Reload config / restart i3 |
| Alt+Shift+e | Exit i3 |
| Alt+Shift+x | Lock the screen (after `install-i3-tools.sh`) |
| Alt+n / Alt+Shift+n | Close notifications / show the last one (after `install-i3-tools.sh`) |

**Copy and paste in the terminal:** select text to copy it, or press **Ctrl+Shift+C**; paste with **Ctrl+Shift+V**. Ctrl+C stops the running program, as in every Linux terminal. With option 1, text you copy in i3 can be pasted in Windows and the other way round (text only; needs `xclip`, which `install-i3.sh` installs). VcXsrv/X410 and Remote Desktop share the clipboard themselves. After updating, run `./set-theme.sh <theme>` once so Alacritty copies on select.

To customise, see [The i3 config](#the-i3-config). To use the Win key anyway, change `set $mod Mod1` to `set $mod Mod4` in `config/i3/config` and run `./install-i3.sh --config`. This works best with the xrdp option.

## Troubleshooting

- **"DISPLAY is not set"** (option 1): WSLg isn't running. Run `wsl --update` and `wsl --shutdown` in PowerShell, then reopen Ubuntu.
- **Xephyr fails to start:** some WSL versions mount `/tmp/.X11-unix` read-only. The script tries to remount it as writable using sudo. Check `/tmp/xephyr-1.log` for details.
- **Every Enter opens a terminal, or every d opens the launcher:** the i3 window thinks Alt is still held, usually after Alt+Tab to a Windows app. `start-i3-wslg.sh` releases the modifier keys when i3 starts, and while i3 runs, `tools/unstick-keys.py` checks four times a second for keys that are held only inside the i3 window, not on your real keyboard, and releases them. If it still happens, press Alt once on its own, or run `fixkeys` in a zsh terminal (from `config/zshrc`). If your keyboard layout isn't detected correctly, set it with `I3_KB_LAYOUT=de ./start-i3-wslg.sh`, for example.
- **"Display :1 is already in use":** pass another display number, e.g. `./start-i3-wslg.sh auto 2`.
- **"Cannot reach an X server"** (option 2): make sure the Windows X server is running, access control is disabled, and the firewall allows it on Public networks.
- **Black screen over RDP:** make sure `~/.xsession` exists and is executable, and that no other i3 session for your user is already running.

## License

[MIT](LICENSE)
