import Foundation
import MacAgentCore
#if canImport(EventKit)
import EventKit
#endif

func printError(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

struct Options {
    var configPath: String?
    var backfill: Int?
    var requestPermissions = false
    var once = false
    var showVersion = false
    var showHelp = false
}

func parseOptions(_ args: [String]) -> Options {
    var o = Options()
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--config":
            o.configPath = it.next()
        case "--backfill":
            guard let v = it.next(), let n = Int(v), n >= 0 else {
                printError("--backfill needs a non-negative integer")
                exit(64)
            }
            o.backfill = n
        case "--request-permissions": o.requestPermissions = true
        case "--once": o.once = true
        case "--version", "-v": o.showVersion = true
        case "--help", "-h": o.showHelp = true
        default:
            printError("unknown argument: \(a)")
            o.showHelp = true
        }
    }
    return o
}

let usage = """
usage: mac-agent [--config PATH] [--backfill N] [--once] [--request-permissions] [--version]

  --config PATH          config file (default ~/Library/Application Support/HouseholdAgent/config.json)
  --backfill N           resend the last N messages, then continue normally
  --once                 do one scan / delivery / command poll / heartbeat and exit
  --request-permissions  ask for Reminders + Calendar access, check Full Disk Access, exit
  --version              print version and exit
"""

/// Placeholder store for platforms without EventKit (tests/CI on Linux).
struct UnavailableStore: ItemStore {
    func findItem(taggedWith tag: String, kind: ItemKind, around date: Date?) async throws -> String? { nil }
    func createReminder(_ p: ReminderPayload) async throws -> String { throw ItemStoreError("EventKit unavailable") }
    func createEvent(_ p: EventPayload) async throws -> String { throw ItemStoreError("EventKit unavailable") }
    func deleteItem(id: String, kind: ItemKind?) async throws -> Bool { throw ItemStoreError("EventKit unavailable") }
    func updateItem(id: String, kind: ItemKind, changes: ItemChanges, notesAppend: String?) async throws -> Bool {
        throw ItemStoreError("EventKit unavailable")
    }
    func permissionFlags() async -> (reminders: Bool, calendar: Bool) { (false, false) }
}

func checkFullDiskAccess(_ config: AgentConfig) -> Bool {
    do {
        let db = try MessagesDatabase(path: config.chatDBURL.path)
        try db.probe()
        return true
    } catch {
        return false
    }
}

func runMain() async -> Int32 {
    let opts = parseOptions(CommandLine.arguments)
    if opts.showHelp {
        print(usage)
        return 0
    }
    if opts.showVersion {
        print("mac-agent \(AgentInfo.version)")
        return 0
    }

    let configURL = opts.configPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AgentPaths.defaultConfig
    let config: AgentConfig
    do {
        config = try AgentConfig.load(from: configURL)
    } catch {
        printError("cannot read config \(configURL.path): \(error)")
        return 78 // EX_CONFIG
    }
    Log.shared.configure(directory: AgentPaths.logsDir, level: LogLevel(name: config.logLevel))

    #if canImport(EventKit)
    let eventKit = EventKitService()
    let store: ItemStore = eventKit
    #else
    let store: ItemStore = UnavailableStore()
    #endif

    if opts.requestPermissions {
        #if canImport(EventKit)
        let flags = await eventKit.requestAccess()
        print("Reminders full access: \(flags.reminders ? "yes" : "NO")")
        print("Calendar full access:  \(flags.calendar ? "yes" : "NO")")
        #else
        print("EventKit is not available on this platform")
        #endif
        let fda = checkFullDiskAccess(config)
        print("Full Disk Access (chat.db readable): \(fda ? "yes" : "NO — add this binary in System Settings → Privacy & Security → Full Disk Access")")
        print("Binary: \(CommandLine.arguments[0])")
        return 0
    }

    #if canImport(EventKit)
    // Under launchd this shows the system prompt the first time (once per signed identity).
    let flags = await eventKit.requestAccess()
    if !flags.reminders || !flags.calendar {
        Log.warn("EventKit access incomplete (reminders=\(flags.reminders), calendar=\(flags.calendar)); commands needing it will fail")
    }
    #endif

    guard let token = TokenSource.agentToken(service: config.keychainService, account: config.keychainAccount) else {
        Log.error("no agent token: store it in the Keychain (service \(config.keychainService), account \(config.keychainAccount)) or set HA_AGENT_TOKEN")
        return 78
    }
    guard let baseURL = URL(string: config.brainURL), baseURL.scheme != nil else {
        Log.error("invalid brain_url '\(config.brainURL)'")
        return 78
    }
    do {
        try AgentPaths.ensureDirectory(AgentPaths.supportDir)
    } catch {
        Log.error("cannot create \(AgentPaths.supportDir.path): \(error)")
        return 73
    }

    let agent = Agent(config: config, client: BrainClient(baseURL: baseURL, token: token), store: store, backfill: opts.backfill)
    if opts.once {
        await agent.runOnce()
        return 0
    }
    await agent.run()
    return 0
}

// Ignore SIGPIPE so a dropped connection never kills the process.
signal(SIGPIPE, SIG_IGN)

// Top-level await: runMain is nonisolated, so the main thread is never blocked.
let code = await runMain()
exit(code)
