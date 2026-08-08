# Fruit

A lightweight command-line tool for local iOS simulator development workflows.

## Overview

Fruit wraps `xcodebuild` and `simctl` so the common edit-build-run loop for an
Xcode app can happen from the terminal.

Instead of remembering long `xcodebuild` and Simulator commands, run:

```sh
fruit run
```

Fruit discovers the current `.xcodeproj`, resolves the scheme, builds for a
selected simulator, boots the simulator if needed, reinstalls the app, and
launches it.

The command describes intent rather than Apple tooling mechanics:

```sh
fruit run
```

means:

```text
Build this app and run it on my selected simulator.
```

## Features

- List available iOS simulators
- Save a project-local selected simulator in `.fruit/config.json`
- Show the selected simulator
- List Xcode schemes for the current project
- Build an app for an iOS simulator using local `.fruit/DerivedData`
- Build, boot, reinstall, and launch with `fruit run`
- Open the current Xcode project
- Clean Fruit-managed build output
- Run diagnostics with `fruit doctor`

## Requirements

- Xcode
- Zsh
- Swift toolchain

## Installation

Clone the repository:

```sh
git clone https://www.github.com/m-tedeschi/fruit.git
cd fruit
```

Run the installer:

```sh
./install.sh
```

The installer builds Fruit and copies the executable to:

```text
~/.fruit/bin/fruit
```

If needed, the installer adds a managed setup block to `~/.zshrc` so `fruit`
is on your `PATH`.

Restart your shell, or reload your shell configuration:

```sh
source ~/.zshrc
```

Verify the installation:

```sh
which fruit
```

Expected output:

```text
/Users/yourname/.fruit/bin/fruit
```

## Usage

| Command | Description |
| --- | --- |
| `fruit` | Show help. |
| `fruit devices` | List available iOS simulators. |
| `fruit device` | Show the selected simulator. |
| `fruit device <device>` | Select a simulator by name or UDID. |
| `fruit schemes` | List Xcode schemes for the current project. |
| `fruit build` | Build for the selected simulator. |
| `fruit build <device>` | Build for a specific simulator without changing the selected simulator. |
| `fruit run` | Build, boot, reinstall, and launch on the selected simulator. |
| `fruit run <device>` | Build, boot, reinstall, and launch on a specific simulator. |
| `fruit clean` | Remove `.fruit/DerivedData`. |
| `fruit open` | Open the current project in Xcode. |
| `fruit doctor` | Check whether Fruit can build and run the current project. |
| `fruit logs` | Omitted from version 0. |

Fruit resolves simulator devices in this order:

1. device argument, if provided
2. saved device in `.fruit/config.json`, if valid
3. exactly one booted simulator, if present
4. fail with a message suggesting `fruit devices` or `fruit device <device>`

Version 0 supports simulator devices only. It expects exactly one `.xcodeproj`
in the current directory tree and exactly one Xcode scheme.

## Future Improvements

- Improve `fruit devices` output with a compact, readable table
- Reduce raw `xcodebuild` noise during successful builds
- Add `fruit logs` for streaming logs from the launched app
- Add explicit simulator controls such as boot, shutdown, and uninstall
- Support workspaces and multiple schemes
