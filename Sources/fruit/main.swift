import Darwin
import Foundation

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

enum FruitError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case .message(let message):
            return message
        }
    }
}

struct Shell {
    static func run(_ arguments: [String], printCommand: Bool = false) throws -> CommandResult {
        if printCommand {
            print(arguments.map(quote).joined(separator: " "))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static func stream(_ arguments: [String]) throws -> Int32 {
        print(arguments.map(quote).joined(separator: " "))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func quote(_ value: String) -> String {
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct SimctlDevice: Codable {
    let name: String
    let udid: String
    let state: String
    let isAvailable: Bool?
}

struct SimctlDevicesResponse: Codable {
    let devices: [String: [SimctlDevice]]
}

struct Device: Codable {
    let name: String
    let udid: String
    let runtime: String
    let state: String

    var isBooted: Bool { state == "Booted" }
}

struct FruitConfig: Codable {
    let simulatorUDID: String
    let simulatorName: String
    let runtime: String
}

struct ProjectContext {
    let root: URL
    let project: URL
    let fruitDirectory: URL
    let configFile: URL
    let derivedData: URL
}

struct Fruit {
    let fileManager = FileManager.default

    func run() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            try dispatch(arguments)
        } catch {
            fputs("fruit: \(error)\n", stderr)
            exit(1)
        }
    }

    private func dispatch(_ arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }

        let rest = Array(arguments.dropFirst())

        switch command {
        case "help", "-h", "--help":
            printHelp()
        case "devices":
            try listDevices()
        case "device":
            if let deviceName = rest.first {
                try setDevice(deviceName)
            } else {
                try printCurrentDevice()
            }
        case "schemes":
            try listSchemes()
        case "build":
            try build(deviceArgument: rest.first)
        case "run":
            try runApp(deviceArgument: rest.first)
        case "clean":
            try clean()
        case "open":
            try openProject()
        case "doctor":
            try doctor()
        case "logs":
            throw FruitError.message("`fruit logs` is omitted from version 0.")
        default:
            throw FruitError.message("unknown command `\(command)`. Run `fruit help`.")
        }
    }

    private func printHelp() {
        print("""
        Fruit

        Usage:
          fruit devices            List available simulators
          fruit device             Show the selected simulator
          fruit device <device>    Select a simulator by name or UDID
          fruit schemes            List Xcode schemes
          fruit build [device]     Build for a simulator
          fruit run [device]       Build, boot, reinstall, and launch
          fruit clean              Remove .fruit/DerivedData
          fruit open               Open the project in Xcode
          fruit doctor             Check whether the project can run
        """)
    }

    private func listDevices() throws {
        let devices = try availableDevices()
        if devices.isEmpty {
            print("No available simulators found.")
            return
        }

        for device in devices {
            let marker = device.isBooted ? "booted" : "shutdown"
            print("\(device.name) (\(device.runtime), \(marker))")
            print("  \(device.udid)")
        }
    }

    private func printCurrentDevice() throws {
        let context = try discoverProject()
        guard let config = try readConfig(context: context) else {
            print("No selected device.")
            print("Run `fruit devices`, then `fruit device <device>`.")
            return
        }

        let devices = try availableDevices()
        if devices.contains(where: { $0.udid == config.simulatorUDID }) {
            print("\(config.simulatorName) (\(config.runtime))")
            print(config.simulatorUDID)
        } else {
            print("Saved device no longer exists:")
            print("\(config.simulatorName) (\(config.runtime))")
            print(config.simulatorUDID)
            print("")
            print("Run `fruit devices`, then `fruit device <device>`.")
        }
    }

    private func setDevice(_ deviceName: String) throws {
        let context = try discoverProject()
        let device = try resolveNamedDevice(deviceName)
        try fileManager.createDirectory(at: context.fruitDirectory, withIntermediateDirectories: true)

        let config = FruitConfig(
            simulatorUDID: device.udid,
            simulatorName: device.name,
            runtime: device.runtime
        )
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: context.configFile)

        print("Selected \(device.name) (\(device.runtime))")
        print(device.udid)
    }

    private func listSchemes() throws {
        let context = try discoverProject()
        for scheme in try schemes(context: context) {
            print(scheme)
        }
    }

    private func build(deviceArgument: String?) throws {
        let context = try discoverProject()
        let scheme = try defaultScheme(context: context)
        let device = try resolveDevice(deviceArgument: deviceArgument, context: context)
        try build(context: context, scheme: scheme, device: device)
    }

    private func runApp(deviceArgument: String?) throws {
        let context = try discoverProject()
        let scheme = try defaultScheme(context: context)
        let device = try resolveDevice(deviceArgument: deviceArgument, context: context)

        try build(context: context, scheme: scheme, device: device)

        _ = try Shell.run(["xcrun", "simctl", "boot", device.udid])
        _ = try Shell.run(["open", "-a", "Simulator"])

        let appPath = try builtAppPath(context: context, scheme: scheme)
        let bundleID = try bundleIdentifier(context: context, scheme: scheme, device: device)

        _ = try Shell.run(["xcrun", "simctl", "uninstall", device.udid, bundleID])

        let install = try Shell.run(["xcrun", "simctl", "install", device.udid, appPath.path], printCommand: true)
        guard install.succeeded else {
            throw FruitError.message("install failed:\n\(install.stderr)")
        }

        let launch = try Shell.run(["xcrun", "simctl", "launch", device.udid, bundleID], printCommand: true)
        guard launch.succeeded else {
            throw FruitError.message("launch failed:\n\(launch.stderr)")
        }

        print(launch.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func clean() throws {
        let context = try discoverProject()
        if fileManager.fileExists(atPath: context.derivedData.path) {
            try fileManager.removeItem(at: context.derivedData)
            print("Removed \(relativePath(context.derivedData, from: context.root))")
        } else {
            print("Nothing to clean.")
        }
    }

    private func openProject() throws {
        let context = try discoverProject()
        let result = try Shell.run(["open", context.project.path], printCommand: true)
        guard result.succeeded else {
            throw FruitError.message("failed to open project:\n\(result.stderr)")
        }
    }

    private func doctor() throws {
        print("Fruit Doctor\n")

        var hasError = false

        print("Xcode")
        hasError = !doctorCommand("xcodebuild", label: "xcodebuild found") || hasError
        hasError = !doctorCommand("xcrun", label: "xcrun found") || hasError
        let selectedXcode = try? Shell.run(["xcode-select", "-p"])
        if let selectedXcode, selectedXcode.succeeded {
            print("  ok     selected Xcode: \(selectedXcode.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            print("  error  could not read selected Xcode path")
            hasError = true
        }

        print("\nProject")
        let context: ProjectContext
        do {
            context = try discoverProject()
            print("  ok     found project: \(context.project.lastPathComponent)")
        } catch {
            print("  error  \(error)")
            print("\nFix")
            print("  cd into an Xcode project directory.")
            exit(1)
        }

        let scheme: String?
        do {
            let foundSchemes = try schemes(context: context)
            if foundSchemes.count == 1 {
                scheme = foundSchemes[0]
                print("  ok     found scheme: \(foundSchemes[0])")
            } else if foundSchemes.isEmpty {
                scheme = nil
                print("  error  no schemes found")
                hasError = true
            } else {
                scheme = nil
                print("  error  multiple schemes found: \(foundSchemes.joined(separator: ", "))")
                hasError = true
            }
        } catch {
            scheme = nil
            print("  error  could not list schemes: \(error)")
            hasError = true
        }

        print("  ok     DerivedData path: \(relativePath(context.derivedData, from: context.root))")
        do {
            try fileManager.createDirectory(at: context.derivedData, withIntermediateDirectories: true)
            print("  ok     DerivedData is writable")
        } catch {
            print("  error  DerivedData is not writable: \(error)")
            hasError = true
        }

        if let scheme {
            do {
                let bundleID = try bundleIdentifierFromProjectFile(context: context) ?? "not inferred"
                print("  ok     bundle id: \(bundleID)")
            } catch {
                print("  error  could not infer bundle id for \(scheme)")
                hasError = true
            }
        }

        print("\nSimulator")
        let devices: [Device]
        do {
            devices = try availableDevices()
            if devices.isEmpty {
                print("  error  no available simulators found")
                hasError = true
            } else {
                print("  ok     available simulators: \(devices.count)")
            }
        } catch {
            devices = []
            print("  error  could not list simulators: \(error)")
            hasError = true
        }

        if let config = try readConfig(context: context) {
            if devices.contains(where: { $0.udid == config.simulatorUDID }) {
                print("  ok     saved simulator: \(config.simulatorName) (\(config.runtime))")
            } else {
                print("  error  saved simulator no longer exists")
                hasError = true
            }
        } else {
            let booted = devices.filter(\.isBooted)
            if booted.count == 1 {
                print("  ok     one booted simulator: \(booted[0].name) (\(booted[0].runtime))")
            } else if booted.count > 1 {
                print("  error  no saved simulator and multiple simulators are booted")
                hasError = true
            } else {
                print("  error  no saved simulator and no simulator is booted")
                hasError = true
            }
        }

        if hasError {
            print("\nFix")
            print("  Run `fruit devices`, then `fruit device <device>` if no simulator is selected.")
            exit(1)
        } else {
            print("\nReady")
            print("  fruit run")
        }
    }

    private func doctorCommand(_ command: String, label: String) -> Bool {
        do {
            let result = try Shell.run(["/usr/bin/which", command])
            if result.succeeded {
                print("  ok     \(label)")
                return true
            }
        } catch {}
        print("  error  \(command) not found")
        return false
    }

    private func build(context: ProjectContext, scheme: String, device: Device) throws {
        try fileManager.createDirectory(at: context.derivedData, withIntermediateDirectories: true)

        let status = try Shell.stream([
            "xcodebuild",
            "-project", context.project.path,
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=\(device.udid)",
            "-derivedDataPath", context.derivedData.path,
            "build"
        ])

        guard status == 0 else {
            throw FruitError.message("build failed")
        }
    }

    private func builtAppPath(context: ProjectContext, scheme: String) throws -> URL {
        let productDirectory = context.derivedData
            .appendingPathComponent("Build")
            .appendingPathComponent("Products")
            .appendingPathComponent("Debug-iphonesimulator")

        let preferred = productDirectory.appendingPathComponent("\(scheme).app")
        if fileManager.fileExists(atPath: preferred.path) {
            return preferred
        }

        let contents = try fileManager.contentsOfDirectory(at: productDirectory, includingPropertiesForKeys: nil)
        let apps = contents.filter { $0.pathExtension == "app" }
        if apps.count == 1 {
            return apps[0]
        }

        throw FruitError.message("could not find built .app in \(productDirectory.path)")
    }

    private func resolveDevice(deviceArgument: String?, context: ProjectContext) throws -> Device {
        if let deviceArgument {
            return try resolveNamedDevice(deviceArgument)
        }

        let devices = try availableDevices()

        if let config = try readConfig(context: context),
           let selected = devices.first(where: { $0.udid == config.simulatorUDID }) {
            return selected
        }

        let booted = devices.filter(\.isBooted)
        if booted.count == 1 {
            return booted[0]
        }

        if booted.count > 1 {
            throw FruitError.message("multiple booted simulators found. Run `fruit device <device>` or pass a device to the command.")
        }

        throw FruitError.message("no selected or booted simulator. Run `fruit devices`, then `fruit device <device>`.")
    }

    private func resolveNamedDevice(_ nameOrUDID: String) throws -> Device {
        let devices = try availableDevices()

        if let device = devices.first(where: { $0.udid.lowercased() == nameOrUDID.lowercased() }) {
            return device
        }

        let matches = devices.filter { $0.name.lowercased() == nameOrUDID.lowercased() }
        if matches.count == 1 {
            return matches[0]
        }

        if let bootedMatch = matches.first(where: \.isBooted) {
            return bootedMatch
        }

        if matches.count > 1 {
            let choices = matches.map { "  \($0.name) (\($0.runtime))\n  \($0.udid)" }.joined(separator: "\n")
            throw FruitError.message("multiple simulators named `\(nameOrUDID)`. Use a UDID:\n\(choices)")
        }

        throw FruitError.message("no available simulator named `\(nameOrUDID)`. Run `fruit devices`.")
    }

    private func availableDevices() throws -> [Device] {
        let result = try Shell.run(["xcrun", "simctl", "list", "devices", "available", "--json"])
        guard result.succeeded else {
            throw FruitError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let response = try JSONDecoder().decode(SimctlDevicesResponse.self, from: Data(result.stdout.utf8))

        return response.devices.flatMap { runtimeIdentifier, simctlDevices in
            simctlDevices.compactMap { simctlDevice in
                guard simctlDevice.isAvailable ?? true else {
                    return nil
                }
                return Device(
                    name: simctlDevice.name,
                    udid: simctlDevice.udid,
                    runtime: displayRuntime(runtimeIdentifier),
                    state: simctlDevice.state
                )
            }
        }
        .filter { $0.runtime.hasPrefix("iOS") }
        .sorted { left, right in
            if left.runtime == right.runtime {
                return left.name < right.name
            }
            return left.runtime > right.runtime
        }
    }

    private func displayRuntime(_ identifier: String) -> String {
        guard let marker = identifier.components(separatedBy: ".").last else {
            return identifier
        }

        if marker.hasPrefix("iOS-") {
            return "iOS " + marker.dropFirst(4).replacingOccurrences(of: "-", with: ".")
        }

        return marker.replacingOccurrences(of: "-", with: " ")
    }

    private func discoverProject() throws -> ProjectContext {
        var directory = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        while true {
            let projects = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "xcodeproj" }

            if projects.count == 1 {
                let root = directory
                let fruitDirectory = root.appendingPathComponent(".fruit")
                return ProjectContext(
                    root: root,
                    project: projects[0],
                    fruitDirectory: fruitDirectory,
                    configFile: fruitDirectory.appendingPathComponent("config.json"),
                    derivedData: fruitDirectory.appendingPathComponent("DerivedData")
                )
            }

            if projects.count > 1 {
                throw FruitError.message("multiple .xcodeproj files found in \(directory.path)")
            }

            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path {
                break
            }
            directory = parent
        }

        throw FruitError.message("no .xcodeproj found in current directory or parents")
    }

    private func schemes(context: ProjectContext) throws -> [String] {
        let result = try Shell.run(["xcodebuild", "-list", "-project", context.project.path])
        guard result.succeeded else {
            throw FruitError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var inSchemes = false
        var schemes: [String] = []

        for rawLine in result.stdout.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Schemes:" {
                inSchemes = true
                continue
            }
            if inSchemes {
                if line.isEmpty {
                    continue
                }
                schemes.append(line)
            }
        }

        return schemes
    }

    private func defaultScheme(context: ProjectContext) throws -> String {
        let foundSchemes = try schemes(context: context)
        if foundSchemes.count == 1 {
            return foundSchemes[0]
        }
        if foundSchemes.isEmpty {
            throw FruitError.message("no schemes found")
        }
        throw FruitError.message("multiple schemes found: \(foundSchemes.joined(separator: ", ")). Version 0 requires exactly one scheme.")
    }

    private func bundleIdentifier(context: ProjectContext, scheme: String, device: Device) throws -> String {
        if let bundleID = try bundleIdentifierFromProjectFile(context: context) {
            return bundleID
        }

        let result = try Shell.run([
            "xcodebuild",
            "-project", context.project.path,
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=\(device.udid)",
            "-derivedDataPath", context.derivedData.path,
            "-showBuildSettings"
        ])

        for line in result.stdout.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER = ") {
                return String(trimmed.dropFirst("PRODUCT_BUNDLE_IDENTIFIER = ".count))
            }
        }

        throw FruitError.message("could not infer bundle identifier")
    }

    private func bundleIdentifierFromProjectFile(context: ProjectContext) throws -> String? {
        let pbxproj = context.project.appendingPathComponent("project.pbxproj")
        let contents = try String(contentsOf: pbxproj, encoding: .utf8)
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("PRODUCT_BUNDLE_IDENTIFIER = ") {
                return trimmed
                    .dropFirst("PRODUCT_BUNDLE_IDENTIFIER = ".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";\""))
            }
        }
        return nil
    }

    private func readConfig(context: ProjectContext) throws -> FruitConfig? {
        guard fileManager.fileExists(atPath: context.configFile.path) else {
            return nil
        }

        let data = try Data(contentsOf: context.configFile)
        return try JSONDecoder().decode(FruitConfig.self, from: data)
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        if urlPath.hasPrefix(rootPath) {
            let relative = urlPath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "." : String(relative)
        }
        return url.path
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

Fruit().run()
