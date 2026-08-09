import Darwin
import Foundation

let fruitVersion = "1.0.1"

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

struct BuildOptions {
    let deviceArgument: String?
    let verbose: Bool
    let outputLogName: String?
}

enum TerminalColor {
    static let red = "\u{001B}[31m"
    static let yellow = "\u{001B}[33m"
    static let green = "\u{001B}[32m"
    static let cyan = "\u{001B}[36m"
    static let bold = "\u{001B}[1m"
    static let reset = "\u{001B}[0m"

    static func red(_ value: String) -> String {
        red + value + reset
    }

    static func yellow(_ value: String) -> String {
        yellow + value + reset
    }

    static func green(_ value: String) -> String {
        green + value + reset
    }

    static func cyan(_ value: String) -> String {
        cyan + value + reset
    }

    static func bold(_ value: String) -> String {
        bold + value + reset
    }
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

final class ProcessOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fruit.process.output")
    private var stdoutData = Data()
    private var stderrData = Data()
    private let printOutput: Bool
    private let outputHandle: FileHandle?

    init(printOutput: Bool, outputHandle: FileHandle?) {
        self.printOutput = printOutput
        self.outputHandle = outputHandle
    }

    func appendStdout(_ data: Data) {
        queue.sync {
            stdoutData.append(data)
            if printOutput {
                FileHandle.standardOutput.write(data)
            }
            outputHandle?.write(data)
        }
    }

    func appendStderr(_ data: Data) {
        queue.sync {
            stderrData.append(data)
            if printOutput {
                FileHandle.standardError.write(data)
            }
            outputHandle?.write(data)
        }
    }

    func result(status: Int32) -> CommandResult {
        queue.sync {
            CommandResult(
                status: status,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
    }
}

struct Shell {
    static func run(_ arguments: [String], printCommand: Bool = false) throws -> CommandResult {
        try execute(arguments, printCommand: printCommand, printOutput: false, outputFile: nil)
    }

    static func stream(_ arguments: [String], outputFile: URL? = nil, printCommand: Bool = true) throws -> Int32 {
        try execute(arguments, printCommand: printCommand, printOutput: true, outputFile: outputFile).status
    }

    static func execute(
        _ arguments: [String],
        printCommand: Bool = false,
        printOutput: Bool = false,
        outputFile: URL? = nil
    ) throws -> CommandResult {
        let outputHandle: FileHandle?
        if let outputFile {
            FileManager.default.createFile(atPath: outputFile.path, contents: nil)
            outputHandle = try FileHandle(forWritingTo: outputFile)
        } else {
            outputHandle = nil
        }
        defer {
            try? outputHandle?.close()
        }

        let output = ProcessOutput(printOutput: printOutput, outputHandle: outputHandle)

        if printCommand || outputHandle != nil {
            let command = commandLine(arguments) + "\n"
            if printCommand {
                print(command, terminator: "")
            }
            if let data = command.data(using: .utf8) {
                outputHandle?.write(data)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            output.appendStdout(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            output.appendStderr(data)
        }

        try process.run()
        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            output.appendStdout(remainingStdout)
        }
        if !remainingStderr.isEmpty {
            output.appendStderr(remainingStderr)
        }

        return output.result(status: process.terminationStatus)
    }

    static func commandLine(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
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
    var simulatorUDID: String? = nil
    var simulatorName: String? = nil
    var runtime: String? = nil
    var scheme: String? = nil
}

enum XcodeContainerKind: String {
    case project
    case workspace

    var pathExtension: String {
        switch self {
        case .project: return "xcodeproj"
        case .workspace: return "xcworkspace"
        }
    }

    var xcodebuildFlag: String {
        switch self {
        case .project: return "-project"
        case .workspace: return "-workspace"
        }
    }

    var displayName: String {
        switch self {
        case .project: return "project"
        case .workspace: return "workspace"
        }
    }
}

struct XcodeContainer {
    let kind: XcodeContainerKind
    let url: URL
}

struct ProjectContext {
    let root: URL
    let container: XcodeContainer
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
        case "version", "-V", "--version":
            printVersion()
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
        case "scheme":
            if let schemeName = rest.first {
                try setScheme(schemeName)
            } else {
                try printCurrentScheme()
            }
        case "build":
            try build(options: parseBuildOptions(rest))
        case "run":
            try runApp(options: parseBuildOptions(rest))
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
        Fruit \(fruitVersion)

        Usage:
          fruit version            Show Fruit version
          fruit devices            List available simulators
          fruit device             Show the selected simulator
          fruit device <device>    Select a simulator by name or UDID
          fruit schemes            List Xcode schemes
          fruit scheme             Show the selected scheme
          fruit scheme <scheme>    Select an Xcode scheme
          fruit build [device]     Build for a simulator
          fruit build --verbose    Build and stream xcodebuild output
          fruit build --o log      Save xcodebuild output to .fruit/log
          fruit run [device]       Build, boot, reinstall, and launch
          fruit run --verbose      Run and stream xcodebuild output
          fruit run --o log        Save xcodebuild output to .fruit/log
          fruit clean              Remove .fruit/DerivedData
          fruit open               Open the project in Xcode
          fruit doctor             Check whether the project can run
        """)
    }

    private func printVersion() {
        print("fruit \(fruitVersion)")
    }

    private func parseBuildOptions(_ arguments: [String]) throws -> BuildOptions {
        var verbose = false
        var outputLogName: String?
        var deviceArguments: [String] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--verbose", "-v":
                verbose = true
            case "--o":
                index += 1
                guard index < arguments.count else {
                    throw FruitError.message("missing file after `--o`")
                }
                guard !arguments[index].hasPrefix("-") else {
                    throw FruitError.message("missing file after `--o`")
                }
                outputLogName = try validatedOutputLogName(arguments[index])
            default:
                if argument.hasPrefix("-") {
                    throw FruitError.message("unknown option `\(argument)`")
                }
                deviceArguments.append(argument)
            }
            index += 1
        }

        if deviceArguments.count > 1 {
            throw FruitError.message("expected at most one device argument")
        }

        return BuildOptions(deviceArgument: deviceArguments.first, verbose: verbose, outputLogName: outputLogName)
    }

    private func validatedOutputLogName(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: name)
        let components = name.split(separator: "/").map(String.init)

        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FruitError.message("output log file cannot be empty")
        }
        guard !url.isFileURL || !name.hasPrefix("/") else {
            throw FruitError.message("output log file must be relative to .fruit")
        }
        guard !components.contains("..") else {
            throw FruitError.message("output log file cannot contain `..`")
        }
        guard !components.contains(".") else {
            throw FruitError.message("output log file cannot contain `.` path components")
        }

        return name
    }

    private func listDevices() throws {
        let devices = try availableDevices()
        if devices.isEmpty {
            print("No available simulators found.")
            return
        }

        let phones = devices.filter { $0.name.hasPrefix("iPhone") }
        let tablets = devices.filter { $0.name.hasPrefix("iPad") }
        let others = devices.filter { !$0.name.hasPrefix("iPhone") && !$0.name.hasPrefix("iPad") }

        print("Available Simulators")

        if !phones.isEmpty {
            printDeviceTable(title: "iPhone", devices: phones)
        }
        if !tablets.isEmpty {
            printDeviceTable(title: "iPad", devices: tablets)
        }
        if !others.isEmpty {
            printDeviceTable(title: "Other", devices: others)
        }

        let suggestedDevice = phones.first ?? devices[0]
        print("")
        print("Select by name or UDID:")
        print("  fruit device \"\(suggestedDevice.name)\"")
        print("  fruit device \(suggestedDevice.udid)")
    }

    private func printDeviceTable(title: String, devices: [Device]) {
        print("")
        print(title)

        let nameWidth = maxColumnWidth(header: "Name", values: devices.map(\.name))
        let runtimeWidth = maxColumnWidth(header: "Runtime", values: devices.map(\.runtime))
        let stateWidth = maxColumnWidth(header: "State", values: devices.map { displayState($0.state) })

        print(
            "  "
            + pad("Name", to: nameWidth)
            + "  "
            + pad("Runtime", to: runtimeWidth)
            + "  "
            + pad("State", to: stateWidth)
            + "  UDID"
        )

        for device in devices {
            print(
                "  "
                + pad(device.name, to: nameWidth)
                + "  "
                + pad(device.runtime, to: runtimeWidth)
                + "  "
                + pad(displayState(device.state), to: stateWidth)
                + "  "
                + device.udid
            )
        }
    }

    private func maxColumnWidth(header: String, values: [String]) -> Int {
        max(([header] + values).map(\.count).max() ?? header.count, header.count)
    }

    private func pad(_ value: String, to width: Int) -> String {
        value + String(repeating: " ", count: max(0, width - value.count))
    }

    private func displayState(_ state: String) -> String {
        state == "Booted" ? "booted" : "shutdown"
    }

    private func printCurrentDevice() throws {
        let context = try discoverProject()
        guard let config = try readConfig(context: context) else {
            print("No selected device.")
            print("Run `fruit devices`, then `fruit device <device>`.")
            return
        }

        let devices = try availableDevices()
        guard let simulatorUDID = config.simulatorUDID,
              let simulatorName = config.simulatorName,
              let runtime = config.runtime else {
            print("No selected device.")
            print("Run `fruit devices`, then `fruit device <device>`.")
            return
        }

        if devices.contains(where: { $0.udid == simulatorUDID }) {
            print("\(simulatorName) (\(runtime))")
            print(simulatorUDID)
        } else {
            print("Saved device no longer exists:")
            print("\(simulatorName) (\(runtime))")
            print(simulatorUDID)
            print("")
            print("Run `fruit devices`, then `fruit device <device>`.")
        }
    }

    private func setDevice(_ deviceName: String) throws {
        let context = try discoverProject()
        let device = try resolveNamedDevice(deviceName)
        try fileManager.createDirectory(at: context.fruitDirectory, withIntermediateDirectories: true)

        var config = try readConfig(context: context) ?? FruitConfig()
        config.simulatorUDID = device.udid
        config.simulatorName = device.name
        config.runtime = device.runtime
        try writeConfig(config, context: context)

        print("Selected \(device.name) (\(device.runtime))")
        print(device.udid)
    }

    private func listSchemes() throws {
        let context = try discoverProject()
        for scheme in try schemes(context: context) {
            print(scheme)
        }
    }

    private func printCurrentScheme() throws {
        let context = try discoverProject()
        let foundSchemes = try schemes(context: context)
        guard let selectedScheme = try readConfig(context: context)?.scheme else {
            if foundSchemes.count == 1 {
                print(foundSchemes[0])
                print("(inferred: only available scheme)")
            } else {
                print("No selected scheme.")
                print("Run `fruit schemes`, then `fruit scheme <scheme>`.")
            }
            return
        }

        if foundSchemes.contains(selectedScheme) {
            print(selectedScheme)
        } else {
            print("Saved scheme no longer exists: \(selectedScheme)")
            print("Run `fruit schemes`, then `fruit scheme <scheme>`.")
        }
    }

    private func setScheme(_ schemeName: String) throws {
        let context = try discoverProject()
        let foundSchemes = try schemes(context: context)
        guard foundSchemes.contains(schemeName) else {
            let choices = foundSchemes.map { "  \($0)" }.joined(separator: "\n")
            throw FruitError.message("no scheme named `\(schemeName)`. Available schemes:\n\(choices)")
        }

        try fileManager.createDirectory(at: context.fruitDirectory, withIntermediateDirectories: true)
        var config = try readConfig(context: context) ?? FruitConfig()
        config.scheme = schemeName
        try writeConfig(config, context: context)

        print("Selected scheme \(schemeName)")
    }

    private func build(options: BuildOptions) throws {
        let context = try discoverProject()
        let scheme = try resolveScheme(context: context)
        let device = try resolveDevice(deviceArgument: options.deviceArgument, context: context)
        try build(context: context, scheme: scheme, device: device, options: options)
    }

    private func runApp(options: BuildOptions) throws {
        let context = try discoverProject()
        let scheme = try resolveScheme(context: context)
        let device = try resolveDevice(deviceArgument: options.deviceArgument, context: context)

        try build(context: context, scheme: scheme, device: device, options: options)

        print("Booting \(device.name) (\(device.runtime))...")
        _ = try Shell.run(["xcrun", "simctl", "boot", device.udid])
        _ = try Shell.run(["open", "-a", "Simulator"])

        let appPath = try builtAppPath(context: context, scheme: scheme)
        let bundleID = try bundleIdentifier(context: context, scheme: scheme, device: device)

        print("Reinstalling \(bundleID)...")
        _ = try Shell.run(["xcrun", "simctl", "uninstall", device.udid, bundleID])

        let install = try Shell.run(["xcrun", "simctl", "install", device.udid, appPath.path])
        guard install.succeeded else {
            throw FruitError.message("install failed:\n\(install.stderr)")
        }

        print("Launching...")
        let launch = try Shell.run(["xcrun", "simctl", "launch", device.udid, bundleID])
        guard launch.succeeded else {
            throw FruitError.message("launch failed:\n\(launch.stderr)")
        }

        let launchOutput = launch.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !launchOutput.isEmpty {
            print(launchOutput)
        }
        print("Run succeeded.")
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
        let result = try Shell.run(["open", context.container.url.path], printCommand: true)
        guard result.succeeded else {
            throw FruitError.message("failed to open \(context.container.kind.displayName):\n\(result.stderr)")
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
            print("  ok     found \(context.container.kind.displayName): \(context.container.url.lastPathComponent)")
        } catch {
            print("  error  \(error)")
            print("\nFix")
            print("  cd into an Xcode project or workspace directory.")
            exit(1)
        }

        let scheme: String?
        do {
            let foundSchemes = try schemes(context: context)
            let selectedScheme = try readConfig(context: context)?.scheme
            if let selectedScheme, foundSchemes.contains(selectedScheme) {
                scheme = selectedScheme
                print("  ok     selected scheme: \(selectedScheme)")
            } else if let selectedScheme {
                scheme = nil
                print("  error  saved scheme no longer exists: \(selectedScheme)")
                hasError = true
            } else if foundSchemes.count == 1 {
                scheme = foundSchemes[0]
                print("  ok     inferred scheme: \(foundSchemes[0])")
            } else if foundSchemes.isEmpty {
                scheme = nil
                print("  error  no schemes found")
                hasError = true
            } else {
                scheme = nil
                print("  error  multiple schemes found and no scheme is selected: \(foundSchemes.joined(separator: ", "))")
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

        let config = try readConfig(context: context)
        if let simulatorUDID = config?.simulatorUDID {
            if let simulatorName = config?.simulatorName,
               let runtime = config?.runtime,
               devices.contains(where: { $0.udid == simulatorUDID }) {
                print("  ok     saved simulator: \(simulatorName) (\(runtime))")
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
            print("  Run `fruit schemes`, then `fruit scheme <scheme>` if no scheme is selected.")
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

    private func build(context: ProjectContext, scheme: String, device: Device, options: BuildOptions) throws {
        try fileManager.createDirectory(at: context.derivedData, withIntermediateDirectories: true)

        print("Building \(scheme) for \(device.name) (\(device.runtime))...")

        let outputFile = try options.outputLogName.map { try outputLogURL(named: $0, context: context) }
        let arguments = [
            "xcodebuild",
        ] + xcodebuildContainerArguments(context: context) + [
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=\(device.udid)",
            "-derivedDataPath", context.derivedData.path,
            "build"
        ]

        let result = try Shell.execute(
            arguments,
            printCommand: options.verbose,
            printOutput: options.verbose,
            outputFile: outputFile
        )
        if let outputFile {
            print("Saved build log to \(relativePath(outputFile, from: context.root))")
        }

        guard result.succeeded else {
            throw FruitError.message(buildFailureMessage(result))
        }

        print(TerminalColor.green("Build succeeded."))
    }

    private func outputLogURL(named name: String, context: ProjectContext) throws -> URL {
        let components = name.split(separator: "/").map(String.init)
        var url = context.fruitDirectory
        for component in components {
            url.appendPathComponent(component)
        }

        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        return url
    }

    private func buildFailureMessage(_ result: CommandResult) -> String {
        let output = [result.stdout, result.stderr]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        let lines = output.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        let diagnostics = buildDiagnostics(from: lines)
        if !diagnostics.errors.isEmpty || !diagnostics.warnings.isEmpty {
            var sections: [String] = [TerminalColor.red("Build failed.")]

            if !diagnostics.errors.isEmpty {
                sections.append("")
                sections.append(TerminalColor.bold("Errors"))
                sections.append(contentsOf: diagnostics.errors.map { "  " + TerminalColor.red($0) })
            }

            if !diagnostics.warnings.isEmpty {
                sections.append("")
                sections.append(TerminalColor.bold("Warnings"))
                sections.append(contentsOf: diagnostics.warnings.map { "  " + TerminalColor.yellow($0) })
            }

            return sections.joined(separator: "\n")
        }

        let tail = lines.suffix(80).joined(separator: "\n")
        if tail.isEmpty {
            return TerminalColor.red("Build failed with exit code \(result.status).")
        }

        return TerminalColor.red("Build failed.") + "\n" + tail
    }

    private func buildDiagnostics(from lines: [String]) -> (errors: [String], warnings: [String]) {
        var errors: [String] = []
        var warnings: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = trimmed.lowercased()

            if isBuildErrorLine(lowercased) {
                appendDiagnostic(trimmed, to: &errors)
            } else if isBuildWarningLine(lowercased) {
                appendDiagnostic(trimmed, to: &warnings)
            }
        }

        return (Array(errors.prefix(12)), Array(warnings.prefix(8)))
    }

    private func isBuildErrorLine(_ lowercasedLine: String) -> Bool {
        lowercasedLine.contains(": error:")
            || lowercasedLine.hasPrefix("error:")
            || lowercasedLine.contains(" error: ")
            || lowercasedLine == "** build failed **"
            || lowercasedLine.contains("unable to open base configuration reference file")
            || lowercasedLine.contains("no such module")
            || lowercasedLine.contains("command phasescriptexecution failed")
    }

    private func isBuildWarningLine(_ lowercasedLine: String) -> Bool {
        lowercasedLine.contains(": warning:")
            || lowercasedLine.hasPrefix("warning:")
            || lowercasedLine.contains(" warning: ")
    }

    private func appendDiagnostic(_ diagnostic: String, to diagnostics: inout [String]) {
        guard !diagnostics.contains(diagnostic) else {
            return
        }
        diagnostics.append(diagnostic)
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
           let simulatorUDID = config.simulatorUDID,
           let selected = devices.first(where: { $0.udid == simulatorUDID }) {
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

        if let match = devices.first(where: { $0.name.lowercased() == nameOrUDID.lowercased() }) {
            return match
        }

        throw FruitError.message("no available simulator named `\(nameOrUDID)`. Run `fruit devices`.")
    }

    private func availableDevices() throws -> [Device] {
        let result = try Shell.run(["xcrun", "simctl", "list", "devices", "available", "--json"])
        guard result.succeeded else {
            throw FruitError.message(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let response = try JSONDecoder().decode(SimctlDevicesResponse.self, from: Data(result.stdout.utf8))

        let devices = response.devices.flatMap { entry -> [Device] in
            let runtimeIdentifier = entry.key
            return entry.value.compactMap { simctlDevice in
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

        return newestDevicePerName(devices)
            .sorted(by: compareDevicesForDisplay)
    }

    private func newestDevicePerName(_ devices: [Device]) -> [Device] {
        var selected: [String: Device] = [:]

        for device in devices {
            let key = device.name.lowercased()
            guard let existing = selected[key] else {
                selected[key] = device
                continue
            }

            if compareDevicesForPreference(device, existing) {
                selected[key] = device
            }
        }

        return Array(selected.values)
    }

    private func compareDevicesForPreference(_ left: Device, _ right: Device) -> Bool {
        let runtimeComparison = compareRuntimeVersions(left.runtime, right.runtime)
        if runtimeComparison != 0 {
            return runtimeComparison > 0
        }

        if left.isBooted != right.isBooted {
            return left.isBooted
        }

        return left.udid < right.udid
    }

    private func compareDevicesForDisplay(_ left: Device, _ right: Device) -> Bool {
        let runtimeComparison = compareRuntimeVersions(left.runtime, right.runtime)
        if runtimeComparison != 0 {
            return runtimeComparison > 0
        }

        return left.name < right.name
    }

    private func compareRuntimeVersions(_ left: String, _ right: String) -> Int {
        let leftComponents = runtimeVersionComponents(left)
        let rightComponents = runtimeVersionComponents(right)
        let count = max(leftComponents.count, rightComponents.count)

        for index in 0..<count {
            let leftValue = index < leftComponents.count ? leftComponents[index] : 0
            let rightValue = index < rightComponents.count ? rightComponents[index] : 0
            if leftValue != rightValue {
                return leftValue < rightValue ? -1 : 1
            }
        }

        return 0
    }

    private func runtimeVersionComponents(_ runtime: String) -> [Int] {
        runtime
            .split(separator: " ")
            .last?
            .split(separator: ".")
            .compactMap { Int($0) } ?? []
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
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            let workspaces = contents.filter { $0.pathExtension == XcodeContainerKind.workspace.pathExtension }
            if workspaces.count == 1 {
                return projectContext(root: directory, container: XcodeContainer(kind: .workspace, url: workspaces[0]))
            }

            if workspaces.count > 1 {
                throw FruitError.message("multiple .xcworkspace files found in \(directory.path)")
            }

            let projects = contents.filter { $0.pathExtension == XcodeContainerKind.project.pathExtension }
            if projects.count == 1 {
                return projectContext(root: directory, container: XcodeContainer(kind: .project, url: projects[0]))
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

        throw FruitError.message("no .xcworkspace or .xcodeproj found in current directory or parents")
    }

    private func projectContext(root: URL, container: XcodeContainer) -> ProjectContext {
        let fruitDirectory = root.appendingPathComponent(".fruit")
        return ProjectContext(
            root: root,
            container: container,
            fruitDirectory: fruitDirectory,
            configFile: fruitDirectory.appendingPathComponent("config.json"),
            derivedData: fruitDirectory.appendingPathComponent("DerivedData")
        )
    }

    private func xcodebuildContainerArguments(context: ProjectContext) -> [String] {
        [context.container.kind.xcodebuildFlag, context.container.url.path]
    }

    private func schemes(context: ProjectContext) throws -> [String] {
        let sharedSchemes = try sharedSchemes(context: context)
        if !sharedSchemes.isEmpty {
            return sharedSchemes
        }

        return try xcodebuildSchemes(context: context)
    }

    private func sharedSchemes(context: ProjectContext) throws -> [String] {
        let schemesDirectory = context.container.url
            .appendingPathComponent("xcshareddata")
            .appendingPathComponent("xcschemes")

        guard fileManager.fileExists(atPath: schemesDirectory.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: schemesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "xcscheme" }
        .map { $0.deletingPathExtension().lastPathComponent }
        .sorted()
    }

    private func xcodebuildSchemes(context: ProjectContext) throws -> [String] {
        let result = try Shell.run(["xcodebuild", "-list"] + xcodebuildContainerArguments(context: context))
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

    private func resolveScheme(context: ProjectContext) throws -> String {
        let foundSchemes = try schemes(context: context)
        if let selectedScheme = try readConfig(context: context)?.scheme {
            if foundSchemes.contains(selectedScheme) {
                return selectedScheme
            }
            throw FruitError.message("saved scheme no longer exists: \(selectedScheme). Run `fruit schemes`, then `fruit scheme <scheme>`.")
        }
        if foundSchemes.count == 1 {
            return foundSchemes[0]
        }
        if foundSchemes.isEmpty {
            throw FruitError.message("no schemes found")
        }
        throw FruitError.message("multiple schemes found: \(foundSchemes.joined(separator: ", ")). Run `fruit scheme <scheme>`.")
    }

    private func bundleIdentifier(context: ProjectContext, scheme: String, device: Device) throws -> String {
        if let bundleID = try bundleIdentifierFromProjectFile(context: context) {
            return bundleID
        }

        let result = try Shell.run([
            "xcodebuild",
        ] + xcodebuildContainerArguments(context: context) + [
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
        guard context.container.kind == .project else {
            return nil
        }

        let pbxproj = context.container.url.appendingPathComponent("project.pbxproj")
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

    private func writeConfig(_ config: FruitConfig, context: ProjectContext) throws {
        try fileManager.createDirectory(at: context.fruitDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(config)
        try data.write(to: context.configFile)
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
