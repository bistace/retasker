# reTasker

A todo system for the reMarkable Paper Pro, built on XOVI and AppLoad. Circle handwriting in any notebook to capture a todo; a standalone app shows them in a list and a calendar, auto-transcribes the ink to text, and can spin up a dated notebook for the day.

This README is the reminder I'll want after a factory reset, when the tablet is back to stock and none of the plumbing exists. It goes in order: get back into the device, put XOVI back, build the four reTasker artifacts, copy them to the right places, reload. Skip ahead if XOVI is already alive — you only need the build and deploy sections.

## What gets installed where

reTasker is not one file. It's a native XOVI extension, an AppLoad backend process, a compiled QML bundle, and four qmldiff patches that splice buttons into xochitl's own UI. Everything lives under `/home/root/xovi` on the device.

| Artifact | Built from | Lands on device at |
| --- | --- | --- |
| `retasker-capture.so` | `src/capture/` | `xovi/extensions.d/retasker-capture.so` (chmod +x) |
| `retasker-backend` | `src/backend/` | `xovi/exthome/appload/retasker/backend/entry` (chmod +x) |
| `retasker-viewer.rcc` | `src/viewer/` | `xovi/exthome/appload/retasker/resources.rcc` |
| `manifest.json` | `src/viewer/manifest.json` | `xovi/exthome/appload/retasker/manifest.json` |
| `icon.png` | `src/viewer/assets/icon.png` | `xovi/exthome/appload/retasker/icon.png` |
| `config.json` | `src/viewer/config.example.json` | `xovi/exthome/appload/retasker/config.json` |
| `retasker-selection.qmd` | `src/selection/` | `xovi/exthome/qt-resource-rebuilder/` |
| `retasker-toolbar.qmd` | `src/selection/` | `xovi/exthome/qt-resource-rebuilder/` |
| `retasker-newnote.qmd` | `src/newnote/` | `xovi/exthome/qt-resource-rebuilder/` |
| `retasker-window.qmd` | `src/appload/` | `xovi/exthome/qt-resource-rebuilder/` |

The native `.so` writes and deletes PNGs and runs the new-note filesystem lookups. The backend owns the SQLite DB (`retasker.db`, created on first run, next to the manifest). The `.rcc` is the viewer UI. The qmds add the "Add to todos" button to the selection menu, the launcher button to the writing toolbar, and the new-note bridge inside xochitl.

The device is a **reMarkable Paper Pro** ("ferrari"), OS **3.27.1.0**. The hashtab and the conditional `framebuffer-spy` import are both tied to that OS version — if you've upgraded the OS, see the gotchas at the bottom before trusting an old hashtab.

## 1. Get back into the tablet

A factory reset wipes the authorized SSH key, the WiFi-SSH marker, and Developer Mode. SSH doesn't exist on the Paper Pro until Developer Mode is back on, so start there: **Settings → General → Paper Tablet → Software → Advanced → Developer Mode**. Turning it on factory-resets the tablet a *second* time, so let anything you care about sync to the cloud first, then wait out the reset.

With Developer Mode on, plug in over USB — the tablet comes up as a USB-ethernet device at `10.11.99.1` and generates a root password. Read it off the tablet under **Settings → General → Help → About → Copyrights and licenses**, beneath the **GPLv3 Compliance** header (it lists the password and the IPs you can reach). Then authorize the dedicated key — the default `~/.ssh/id_ed25519` is deliberately not trusted:

```sh
ssh-copy-id -i ~/.ssh/retasker_tablet_ed25519.pub root@10.11.99.1
```

Confirm it works:

```sh
ssh -i ~/.ssh/retasker_tablet_ed25519 -o IdentitiesOnly=yes root@10.11.99.1 'echo ok'
```

The Paper Pro disables SSH over WiFi by default, and the USB-ethernet link sleeps when idle, so turn on WiFi access — it survives reboots and OS updates:

```sh
ssh -i ~/.ssh/retasker_tablet_ed25519 -o IdentitiesOnly=yes root@10.11.99.1 'rm-ssh-over-wlan on'
```

From here on, `~/bin/rmpp '<cmd>'` resolves the tablet's DHCP address by its wlan0 MAC and SSHes in over WiFi. DHCP can hand it a new IP, so always let `rmpp` find it rather than hardcoding one. `rmpp` prints `rmpp: found at <ip>` to stderr — grab that IP for `scp`.

## 2. Put XOVI back

reTasker needs XOVI plus four modules: `appload`, `framebuffer-spy`, `qt-resource-rebuilder`, `xovi-message-broker`. **Install the XOVI core the manual way, not through vellum** — `vellum add xovi` skips the `start`, `stock`, `debug`, and `rebuild_hashtable` scripts you need to load, reload, and maintain it. The four modules then come cleanly from **vellum**, the reMarkable package manager. Everything here runs on the tablet over SSH (`rmpp '<cmd>'`), and the tablet needs internet — the installer pulls XOVI from GitHub.

Grab `extensions-aarch64.zip` from the [rm-xovi-extensions releases](https://github.com/asivery/rm-xovi-extensions/releases), unzip it, and copy the installer to the tablet (use the IP `rmpp` prints):

```sh
IP=$(rmpp true 2>&1 >/dev/null | sed -n 's/.*found at //p')
scp -i ~/.ssh/retasker_tablet_ed25519 -o IdentitiesOnly=yes \
    install-xovi-for-rm root@$IP:/home/root/
```

Run it on the device — it downloads `xovi.so` and lays down `/home/root/xovi/` with the `start`, `stock`, `debug`, and `rebuild_hashtable` scripts:

```sh
rmpp 'chmod +x /home/root/install-xovi-for-rm && /home/root/install-xovi-for-rm'
```

Now install vellum for the modules. Pull the current bootstrap one-liner and its checksum from the [vellum-cli releases page](https://github.com/vellum-dev/vellum-cli/releases/latest); it downloads, verifies, and runs `bootstrap.sh`, landing vellum at `/home/root/.vellum/bin/vellum`:

```sh
rmpp 'wget --no-check-certificate -O bootstrap.sh \
  https://github.com/vellum-dev/vellum-cli/releases/latest/download/bootstrap.sh && bash bootstrap.sh'
```

`bootstrap.sh` adds vellum to `.bashrc`, but that won't carry across separate `rmpp` calls, so invoke it by full path. Refresh the index and pull the four modules:

```sh
rmpp '/home/root/.vellum/bin/vellum update'
rmpp '/home/root/.vellum/bin/vellum add appload framebuffer-spy qt-resource-rebuilder xovi-message-broker'
```

Last known-good set: xovi 0.3.3-r2, appload 0.5.3, the extensions at 19.0.0.

Now build the qmldiff hashtab:

```sh
rmpp '/home/root/xovi/rebuild_hashtable'   # interactive — enter the device password on the tablet screen
```

`rebuild_hashtable` prompts and reads a password typed on the tablet itself; it stops on its own at "Hashtab saved". The hashtab must match the running OS — a 3.24 hashtab on 3.27 loads zero entries and silently crash-loops AppLoad. If you landed here by *upgrading* the OS rather than a clean install, run `vellum reenable` first to restore the system-partition mods (it nags until you do). The qmldiff patches qt-resource-rebuilder reads live in `xovi/exthome/qt-resource-rebuilder/`, which is where reTasker's four `.qmd` files go in the next step.

XOVI is tethered: a full reboot drops back to stock until you run `xovi/start`. Keep that command handy — you'll use it as the reload at the end.

## 3. Build the four artifacts

There's no native aarch64 toolchain on the Mac, so everything builds inside a Docker container holding the official ferrari Yocto SDK. Bring up colima and bake the image once:

```sh
colima start --cpu 4 --memory 8 --disk 60
docker build --platform linux/amd64 -t retasker-toolchain:latest toolchain/
```

The image is amd64 (the SDK installer is an x86_64 self-extracting script) and runs under qemu — slow to build the first time, fine afterward. Then run the three build scripts; each one drops its output in `build/`:

```sh
./build.sh           # build/retasker-capture.so   (native XOVI extension)
./build-backend.sh   # build/retasker-backend      (AppLoad backend, SQLite linked in)
./build-viewer.sh    # build/retasker-viewer.rcc   (compiled QML)
```

The launcher icon is already committed at `src/viewer/assets/icon.png`. Regenerate it only if you've changed the design:

```sh
python3 src/viewer/assets/gen_icon.py src/viewer/assets/icon.png
```

The OCR config carries your OpenRouter key and is git-ignored. Copy the template and fill it in before deploying:

```sh
cp src/viewer/config.example.json src/viewer/config.json
$EDITOR src/viewer/config.json    # set apiKey to your sk-or-... key
```

## 4. Deploy

Grab the device IP once, set up the app directory tree, then copy everything from the table. Adjust the `IP` capture if your `rmpp` output differs.

```sh
IP=$(rmpp true 2>&1 >/dev/null | sed -n 's/.*found at //p')
SCP="scp -i ~/.ssh/retasker_tablet_ed25519 -o IdentitiesOnly=yes"
APP=/home/root/xovi/exthome/appload/retasker
QRR=/home/root/xovi/exthome/qt-resource-rebuilder

rmpp "mkdir -p $APP/backend $APP/captures"

# native extension + qmldiff patches
$SCP build/retasker-capture.so        root@$IP:/home/root/xovi/extensions.d/
$SCP src/selection/retasker-selection.qmd src/selection/retasker-toolbar.qmd \
     src/newnote/retasker-newnote.qmd  src/appload/retasker-window.qmd \
     root@$IP:$QRR/

# the AppLoad app
$SCP build/retasker-backend           root@$IP:$APP/backend/entry
$SCP build/retasker-viewer.rcc        root@$IP:$APP/resources.rcc
$SCP src/viewer/manifest.json         root@$IP:$APP/manifest.json
$SCP src/viewer/assets/icon.png       root@$IP:$APP/icon.png
$SCP src/viewer/config.json           root@$IP:$APP/config.json

rmpp "chmod +x /home/root/xovi/extensions.d/retasker-capture.so $APP/backend/entry"
```

Reload XOVI to pick it all up:

```sh
rmpp '/home/root/xovi/start'
```

`xovi/start` restarts xochitl and may briefly drop the SSH session — that's expected. The `.rcc` re-registers on every app launch, so to see viewer changes later you only need to close and relaunch the app, no `xovi/start` required.

## 5. Check it

Open a notebook, circle some handwriting, and look for **Add to todos** in the selection menu. The writing toolbar gets a reTasker button that opens the viewer over the note; the `</>` AppLoad launcher on the home screen opens it too. Tap a row to toggle done, switch to the calendar, and "+ New note" should create and open a dated notebook in a "reTasker" collection.

If the app doesn't appear, the usual culprit is the hashtab not matching the OS (rebuild it) or a stray backup file in a load directory (see below).

## Gotchas worth re-reading

- **Never leave `.bak` copies inside `extensions.d/` or `qt-resource-rebuilder/`.** Both directories are loaded by scanning, so a leftover `retasker-capture.so.bak` is loaded a second time and xochitl crash-loops with "Extension processed more than once". Keep backups somewhere else, like `/home/root/retasker-landscape-backup/`.
- **The hashtab is per-OS.** Upgrade the OS and the old hashtab loads nothing, which takes AppLoad down quietly. Rerun `xovi/rebuild_hashtable`.
- **`framebuffer-spy` loads conditionally.** The capture extension uses a soft `import?` so it unloads cleanly in xochitl's launcher/setup processes (where Qt isn't mapped) and resolves only in the GUI process. Don't change that import to a hard one — a hard import halts the process that lacks the symbol.
- **Reboot equals stock.** Any full restart leaves XOVI inert until `xovi/start`. The viewer's transcription needs `config.json` present and a valid OpenRouter key, or captures stay as images instead of becoming text.
