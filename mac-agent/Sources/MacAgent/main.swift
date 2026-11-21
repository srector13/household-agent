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
    var probeReminderKit = false
    var probeList = "Household Agent probe"
    var probeWrite = false
    var probeKeep = false
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
        case "--probe-reminderkit": o.probeReminderKit = true
        case "--list":
            guard let v = it.next(), !v.isEmpty else {
                printError("--list needs a list name")
                exit(64)
            }
            o.probeList = v
        case "--write": o.probeWrite = true
        case "--keep": o.probeKeep = true
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
       mac-agent --probe-reminderkit [--write [--list NAME] [--keep]]

  --config PATH          config file (default ~/Library/Application Support/HouseholdAgent/config.json)
  --backfill N           resend the last N messages, then continue normally
  --once                 do one scan / delivery / command poll / heartbeat and exit
  --request-permissions  ask for Reminders + Calendar access, check Full Disk Access, exit
  --version              print version and exit
  --probe-reminderkit    check whether list sections + #tags (private ReminderKit) work on this Mac
      --write            also create a test reminder with section "Probe" and tag #haprobe, read it
                         back and delete it again
      --list NAME        list for the write test (default "Household Agent probe"; created and
                         removed again if it doesn't exist)
      --keep             keep the test reminder (and list) so you can look at it in column view
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
    func listIdentifier(ofReminder id: String) async throws -> String? { nil }
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

    if opts.probeReminderKit {
        return await probeReminderKit(opts)
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

    let organizer: ReminderOrganizer = config.useReminderKit ? ReminderKitOrganizer.platformDefault() : NoReminderOrganizer()
    if !config.useReminderKit { Log.info("ReminderKit disabled in config (use_reminderkit=false): sections/tags use the title fallback") }
    let agent = Agent(config: config, client: BrainClient(baseURL: baseURL, token: token), store: store,
                      organizer: organizer, backfill: opts.backfill)
    if opts.once {
        await agent.runOnce()
        return 0
    }
    await agent.run()
    return 0
}

/// `--probe-reminderkit`: report what ReminderKit offers on this Mac, optionally with a live write test.
func probeReminderKit(_ opts: Options) async -> Int32 {
    print("mac-agent \(AgentInfo.version) — ReminderKit probe (private Apple framework, unsupported)\n")
    guard let rk = ReminderKitOrganizer.platformDefault(honorCrashMarker: false) as? ReminderKitOrganizer else {
        print("ReminderKit is not available on this platform.")
        return 1
    }
    print(await rk.report())
    let available = await rk.isAvailable()
    guard opts.probeWrite else {
        print(available
              ? "\nAll needed pieces exist. Run again with --write to create, verify and delete a test reminder."
              : "\nNot available: reminders that ask for a section or tags will use the title fallback.")
        return available ? 0 : 1
    }
    guard available else {
        print("\nSkipping the write test because ReminderKit is not available.")
        return 1
    }
    #if canImport(EventKit)
    let ek = EventKitService()
    let flags = await ek.requestAccess()
    guard flags.reminders else {
        print("\nNo Reminders access for this binary — grant it first (mac-agent --request-permissions).")
        return 1
    }
    let listExisted = await ek.reminderListIdentifier(named: opts.probeList) != nil
    let tag = "[ha:probe:\(UUID().uuidString.prefix(8))]"
    let id: String
    do {
        id = try await ek.createReminder(ReminderPayload(
            title: "Household Agent probe — safe to delete", list: opts.probeList, createListIfMissing: true,
            notes: "Created by mac-agent --probe-reminderkit\n\(tag)"))
    } catch {
        print("\nCould not create the test reminder: \(error)")
        return 1
    }
    print("\nCreated test reminder \(id) in '\(opts.probeList)'\(listExisted ? "" : " (new list)")")
    var passed = false
    do {
        guard let listId = try await ek.listIdentifier(ofReminder: id) else { throw OrganizerError("list not found") }
        try await rk.apply(listIdentifier: listId, reminderIdentifier: id, section: "Probe", tags: ["haprobe"])
        print("apply section 'Probe' + #haprobe: saved without error")
        let back = await rk.readBack(listIdentifier: listId, reminderIdentifier: id)
        let tagOK = back.tags.contains("haprobe")
        let sectionOK = back.section == "Probe"
        print("read back: tags=\(back.tags.isEmpty ? "(none)" : back.tags.joined(separator: ","))"
              + " section=\(back.section ?? "(could not read)")" + (back.error.map { "  error: \($0)" } ?? ""))
        print("  #tag:    \(tagOK ? "VERIFIED" : "NOT verified")")
        print("  section: \(sectionOK ? "VERIFIED" : back.section == nil ? "not readable on this macOS — check the list in column view (use --keep)" : "WRONG (\(back.section!))")")
        passed = tagOK && (sectionOK || back.section == nil)
    } catch {
        print("apply FAILED: \(error)")
    }
    if opts.probeKeep {
        print("\nKept the test reminder (--keep). Open Reminders → '\(opts.probeList)' → View → as Columns.")
    } else {
        _ = try? await ek.deleteItem(id: id, kind: .reminder)
        if !listExisted, let lid = await ek.reminderListIdentifier(named: opts.probeList) {
            try? await ek.deleteReminderList(identifier: lid)
        }
        print("\nCleaned up the test reminder\(listExisted ? "" : " and list").")
    }
    if rk.foundCrashMarker {
        print(passed ? "\nA previous ReminderKit call had crashed the agent; this test passed, so it is re-enabled."
                     : "\nNote: a previous ReminderKit call crashed the agent; it stays disabled.")
    }
    if passed { rk.clearCrashMarker() }
    print(passed ? "\nRESULT: sections + tags work on this Mac. Restart the agent to pick this up:\n"
                   + "  launchctl kickstart -k gui/$(id -u)/com.household.mac-agent"
                 : "\nRESULT: not working — the agent will use the title fallback.")
    return passed ? 0 : 1
    #else
    print("EventKit is not available on this platform.")
    return 1
    #endif
}

// Ignore SIGPIPE so a dropped connection never kills the process.
signal(SIGPIPE, SIG_IGN)

// Top-level await: runMain is nonisolated, so the main thread is never blocked.
let code = await runMain()
exit(code)
