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
./i3-wsl.sh wslg [SIZE] [DISP]   # option 1, e.g. ./i3-wsl.sh wslg 2560x1440
./i3-wsl.sh xserver [DISP]       # option 2
./i3-wsl.sh xrdp [PORT]          # option 3
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
./start-i3-wslg.sh                 # 1920x1080 on display :1
./start-i3-wslg.sh 2560x1440       # custom size
./start-i3-wslg.sh 2560x1440 2     # custom size and display number
```

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

## Uninstall

```bash
./uninstall-i3.sh          # asks before each step
./uninstall-i3.sh --yes    # no questions
```

You can also pick **Uninstall** from the `i3-wsl.sh` menu. The script:

- Stops and removes xrdp, if it was installed
- Removes i3, i3status, i3lock, dmenu, rofi and Xephyr
- Asks separately before removing general X tools (xterm, feh, x11-apps and others), since other Linux GUI apps may use them
- Runs `apt-get autoremove`, which lists what it will remove and asks first (unless you used `--yes`)
- Deletes `~/.xsession` only if it is still the version `setup-xrdp.sh` wrote
- Moves `~/.config/i3` to a timestamped backup rather than deleting it

It never removes `iproute2` or `fonts-dejavu-core`, since other software relies on them.

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
- **"Display :1 is already in use":** pass another display number, e.g. `./start-i3-wslg.sh 1920x1080 2`.
- **"Cannot reach an X server"** (option 2): make sure the Windows X server is running, access control is disabled, and the firewall allows it on Public networks.
- **Black screen over RDP:** make sure `~/.xsession` exists and is executable, and that no other i3 session for your user is already running.

## License

[MIT](LICENSE)
