---
name: Bug report
about: A source is not detected, an export or date fix fails, or the app or CLI misbehaves
title: ''
labels: bug
---

**What did you do?**

<!-- e.g. "Connected the console, opened Tethersnap, clicked Export All", "Inserted the PS5 drive", or the exact CLI command. -->

**What did you expect?**

**What happened instead?**

<!-- Error text or a screenshot. -->

**Log file**

Attach `~/Library/Logs/Tethersnap/Tethersnap.log` (Help → Reveal Log File in Finder), plus `Tethersnap.previous.log` beside it if the problem happened in an earlier run. For CLI issues, attach the output of `tethersnap sources` and `tethersnap probe --verbose 2>&1` (the log lines go to stderr). The log file lists every capture filename and game, drive, or folder name along with file paths. Redact the device serial number, your macOS user name (it appears in file paths), and any names you would rather not share.

**Environment**

- Tethersnap version (About window or `tethersnap --version`):
- macOS version:
- Source: Nintendo Switch 2 / original Switch (with its system firmware version), camera model and USB mode, or the drive/folder layout (PS5, PS4, Switch SD card, camera card, plain folder):
- Cable and port (console bottom USB-C port, dock, hub, card reader?):
- Is Android File Transfer, OpenMTP, or MacDroid installed? Is Image Capture or Photos set to open when the device connects?
