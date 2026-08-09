# Idea -- Fruit


## Overview

Fruit is a command-line tool that will aid in Apple ecosystem developer workflows.

Fruit stores its project-local settings in `.fruit/config.json`.

It will be written in Swift.

Usage / Commands:

* `fruit` (no arguments): displays Fruit help
* `fruit devices`: lists available devices
* `fruit device`: displays the current selected device
* `fruit device <device>`: sets the selected device
* `fruit schemes`: lists Xcode schemes of the current project
* `fruit scheme`: displays the current selected scheme
* `fruit scheme <scheme>`: sets the selected scheme
* `fruit build`: builds the app using sane defaults
* `fruit build <device>`: builds the app using sane defaults for device
* `fruit run`: build for selected device, boot simulator (if it's not running already), install the
  app, launch it
* `fruit run <device>`: builds for a specific device, boots that simulator,
  installs the app to it, launches it
* `fruit clean`: remove local DerivedData/build output
* `fruit open`: opens the current project in Xcode
* `fruit doctor`: inspect the local project, determine if fruit can work/run
  (see doctor section) 
* `fruit logs`: streams logs from the running app. Omit from version 0

## Version 0 Constraints

* simulator devices only
* supports one `.xcworkspace` or one `.xcodeproj` in the current project tree
* prefers a single `.xcworkspace` when present, because CocoaPods projects should
  build through the workspace
* if multiple schemes exist, version 0 requires the user to choose with
  `fruit scheme <scheme>`; version 0 uses the only scheme when exactly one
  scheme exists
* `fruit logs` is omitted from version 0

## Device Resolution

For commands that need a simulator device, such as `fruit build` and `fruit run`,
Fruit resolves the device in this order:

1. device argument, if provided
2. saved device in `.fruit/config.json`, if valid
3. exactly one booted simulator, if present
4. fail with a helpful message that suggests `fruit devices` or `fruit device <device>`

## Scheme Resolution

For commands that need an Xcode scheme, such as `fruit build` and `fruit run`,
Fruit resolves the scheme in this order:

1. saved scheme in `.fruit/config.json`, if valid
2. exactly one available scheme, if present
3. fail with a helpful message that suggests `fruit schemes` or `fruit scheme <scheme>`

Fruit should read shared scheme files directly from the selected project or
workspace when possible, and fall back to `xcodebuild -list` only when no shared
schemes are found.

## Doctor

`fruit doctor` inspects the current project and local Apple developer tooling without
building or running the app. Its job is to explain whether Fruit has enough context
to run successfully, and if not, what the user should fix.

Checks should include:

* `xcodebuild` is available
* `xcrun simctl` is available
* selected Xcode path from `xcode-select -p`
* available simulator runtimes
* available iPhone simulators
* current `.xcodeproj` or `.xcworkspace`
* available schemes
* saved selected scheme still exists, if configured
* inferred app bundle identifier
* `.fruit/config.json` exists and is valid JSON, if present
* saved selected simulator UDID still exists, if configured
* `.fruit/DerivedData` is writable

The output should avoid dumping raw `xcodebuild` noise. It should translate common
setup problems into clear next steps.

Example:

```text
Fruit Doctor

Xcode
  ok     xcodebuild found
  ok     selected Xcode: /Applications/Xcode.app

Project
  ok     found project: TestXcodeApp.xcodeproj
  ok     found scheme: TestXcodeApp
  ok     bundle id: com.example.TestXcodeApp

Simulator
  error  saved simulator no longer exists

Fix
  fruit devices
  fruit device "iPhone 16"
```
