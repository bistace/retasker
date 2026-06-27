# reTasker

reTasker is a todo system for the reMarkable Paper Pro that turns handwriting into a tracked task list. You circle a few words in any notebook, tap a button, and the selection becomes a todo. A companion application transcribes the ink to text, shows everything as a list or a calendar, and can open a fresh dated notebook for the day.

It is built on [XOVI](https://github.com/asivery/rm-xovi-extensions) and AppLoad, and installs as a package through [vellum](https://vellum.delivery).

## Features

- **Capture from handwriting.** Select handwriting in any notebook and tap **Add to todos** in the selection menu. The snippet is saved and added to your list.
- **Automatic transcription.** New captures are transcribed to text the next time you open the viewer, using a vision model of your choice through OpenRouter. The original ink is kept until the transcription succeeds.
- **List and calendar views.** A standalone application shows your todos as a flat list or a monthly calendar. Each day carries a small progress arc for completed versus total, and days holding todos or notes are marked.
- **Subtasks.** Todos can be nested under a parent and collapsed, which keeps long lists readable.
- **Tap to complete, filter to focus.** Tap a row to mark it done, and switch the view between open, done, and all.
- **Manual entry and editing.** Add todos directly from the list or the calendar, one per line, and long-press any todo to modify or delete it.
- **Dated notebooks.** The **+ New note** button creates and opens a date-named notebook inside a "reTasker" collection, ready for the day's writing.

## Requirements

reTasker targets the **reMarkable Paper Pro** (codename ferrari) running OS **3.27.x**. It will not install on other firmware, as the interface patches are tied to a specific version.

You will need a device with:

- Developer mode enabled and SSH access. The [reMarkable Guide](https://remarkable.guide) covers this for the Paper Pro.
- [XOVI](https://github.com/asivery/rm-xovi-extensions) installed, with its qmldiff hashtable built for your OS.
- [vellum](https://vellum.delivery), the reMarkable package manager.

The XOVI extensions reTasker relies on — appload, qt-resource-rebuilder, xovi-message-broker and framebuffer-spy — are pulled in automatically by vellum, so you do not need to install them by hand.

## Installation

All commands below run on the tablet over SSH.

First, tell vellum to trust the reTasker signing key and add the package repository:

```sh
wget -O /home/root/.vellum/etc/apk/keys/retasker.rsa.pub \
  https://bistace.github.io/retasker/retasker.rsa.pub
echo "https://bistace.github.io/retasker" >> /home/root/.vellum/etc/apk/repositories
```

Then refresh the index and install:

```sh
vellum update
vellum add retasker
```

This pulls reTasker together with its XOVI dependencies. The interface patches need the qmldiff hashtable to be built for your firmware. If you have not done this already for your current OS, run:

```sh
xovi/rebuild_hashtable   # interactive — enter the device password shown on the tablet
```

Finally, reload XOVI to activate everything:

```sh
xovi/start
```

If everything went fine, you will find an **Add to todos** entry in the selection menu when you circle handwriting, a reTasker button on the writing toolbar, and a reTasker launcher on the home screen.

## Transcription

Transcription turns your captured handwriting into text. It is optional: without it, each capture stays in the list as the ink image you selected.

reTasker sends snippets to [OpenRouter](https://openrouter.ai), which lets you pick any supported vision model. Edit the configuration file and set your API key:

```sh
vi /home/root/xovi/exthome/appload/retasker/config.json
```

```json
{
    "endpoint": "https://openrouter.ai/api/v1/chat/completions",
    "apiKey": "sk-or-...",
    "model": "google/gemini-3.5-flash",
    "prompt": "You are an OCR system. The image is a short handwritten note. Transcribe it exactly as written..."
}
```

The `model` field accepts any OpenRouter model identifier, and `prompt` lets you adapt the instructions, for instance to set the expected language. Your key stays on the device and is never part of the package, so updates and reinstalls leave the file untouched.

## Usage

Write in a notebook as you normally would. To capture a task, select the relevant handwriting with the selection tool and tap **Add to todos**. The snippet is saved and shows up in the viewer.

Open the viewer from the reTasker button on the writing toolbar, or from the launcher on the home screen. Tap a row to toggle it done, and use the filter to move between open, done, and all todos. Switch to the calendar to see your tasks day by day, each day showing how many are completed. To plan a day on paper, tap **+ New note**: reTasker creates a notebook named for the date inside a "reTasker" collection and opens it.

## Updating

```sh
vellum update && vellum add retasker
```

Your todos, the database and the configuration are preserved across updates.

## Uninstalling

```sh
vellum del retasker
```

This also removes the shared XOVI modules when nothing else depends on them. To keep them, mark them as explicitly installed first with `vellum add appload qt-resource-rebuilder xovi-message-broker framebuffer-spy`. To remove reTasker together with its database and settings, use `vellum purge retasker` instead.

## How it works

reTasker is made of four parts that communicate through the xovi-message-broker:

- a native XOVI extension that writes the handwriting snippets and runs the new-note lookups,
- a backend process that owns the SQLite database of todos,
- a compiled QML application, the viewer, launched through AppLoad,
- and a set of qmldiff patches that splice the buttons into xochitl's own interface.

The viewer ships no SQLite of its own, so it asks the backend for a page of todos and renders it, while the backend handles sorting and calendar bucketing. The captured PNG snippets are the only files left on disk, and each one is removed once its transcription has been stored.

## Building from source

Contributors can build the artifacts themselves. The cross-compilation runs inside a Docker image holding the official ferrari Yocto SDK.

```sh
colima start --cpu 4 --memory 8 --disk 60          # or any Docker provider
docker build --platform linux/amd64 -t retasker-toolchain:latest toolchain/

./build.sh           # native XOVI capture extension -> build/retasker-capture.so
./build-backend.sh   # AppLoad backend, SQLite linked -> build/retasker-backend
./build-viewer.sh    # compiled viewer QML            -> build/retasker-viewer.rcc
```

`bundle-release.sh` assembles these into the release tarball that the package consumes, and `packages/retasker/VELBUILD` describes the package. Tagging a GitHub release builds and publishes a signed package automatically.

## License

reTasker is released under the GNU General Public License v3.0. See [LICENSE](LICENSE).

## Issues

In case of troubles when installing or using reTasker, please open an issue on the [project page](https://github.com/bistace/retasker/issues).
