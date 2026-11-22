import Foundation

/// Orchestrates the agent: watches chat.db, delivers events through the offline buffer, executes
/// commands from the brain and sends heartbeats. All mutable state is isolated to this actor.
public actor Agent {
    public let config: AgentConfig
    private let client: BrainClient
    private let store: ItemStore
    private let organizer: ReminderOrganizer
    private let executor: CommandExecutor
    private let checkpoint: Checkpoint
    private let buffer: OfflineBuffer
    private var builder: EventBuilder
    private let backfill: Int?
    private let syncedConfigURL: URL
    /// Allowlist synced from the brain (only used when config.syncAllowlist).
    private var allowlist: SyncedAllowlist?
    /// True once the brain answered 404 for /api/agent/config (older brain): fall back to the local
    /// prefilter so events are not held forever.
    private var syncUnsupported = false
    private var holdLogged = false
    private let startedAt = Date()

    private var messagesDB: MessagesDatabase?
    private var fdaOK = false
    private var checkpointReady = false
    private var isFlushing = false
    private var watcher: FileWatcher?
    private var lastDBError: String?

    private let scanWakeup = Wakeup()
    private let sendWakeup = Wakeup()

    // Completion sync (see ItemStatus.swift)
    private var statusSchedule = StatusSyncSchedule()
    private var statusSyncRunning = false
    private let statusWakeup = Wakeup()

    // Full-picture calendar snapshot (see Snapshot.swift)
    private var snapshotDisabled = false
    private let snapshotRangeDays = CalendarSnapshot.defaultRangeDays

    // Contact photos (see Avatars.swift)
    private let contacts: ContactsSource
    private let avatarStateURL: URL
    private var avatarsDisabled = false
    private var avatarSyncRunning = false

    public init(config: AgentConfig, client: BrainClient, store: ItemStore,
                organizer: ReminderOrganizer = NoReminderOrganizer(),
                stateURL: URL = AgentPaths.state, bufferURL: URL = AgentPaths.buffer,
                syncedConfigURL: URL = AgentPaths.syncedConfig,
                contacts: ContactsSource = NoContactsSource(), avatarStateURL: URL = AgentPaths.avatarState,
                backfill: Int? = nil, timeZone: TimeZone = .current) {
        self.config = config
        self.contacts = contacts
        self.avatarStateURL = avatarStateURL
        self.client = client
        self.store = store
        self.organizer = organizer
        self.executor = CommandExecutor(store: store, organizer: organizer)
        self.checkpoint = Checkpoint(url: stateURL)
        self.buffer = OfflineBuffer(url: bufferURL)
        self.backfill = backfill
        self.syncedConfigURL = syncedConfigURL
        let cached = config.syncAllowlist ? SyncedAllowlist.load(from: syncedConfigURL) : nil
        self.allowlist = cached
        self.builder = EventBuilder(config: config, timeZone: timeZone,
                                    prefilter: config.syncAllowlist ? .synced(cached) : .local)
    }

    // MARK: Allowlist sync

    /// The allowlist currently in force at send time, or nil when nothing should be filtered here
    /// (sync off with an empty local list is handled by the builder's `.local` prefilter).
    private var usesSyncedFilter: Bool { config.syncAllowlist && !syncUnsupported }

    public var allowlistVersion: Int? { usesSyncedFilter ? allowlist?.settingsVersion : nil }

    public var allowlistSize: Int {
        usesSyncedFilter ? (allowlist?.size ?? 0) : config.allowHandles.count
    }

    /// Applies a config fetched from the brain: caches it on disk and wakes the sender so held
    /// events are re-evaluated.
    public func applyRemoteConfig(_ remote: RemoteAgentConfig) async {
        let list = SyncedAllowlist(remote: remote, syncedAt: ISO8601DateFormatter().string(from: Date()))
        let changed = list.settingsVersion != allowlist?.settingsVersion || list.handles != allowlist?.handles
            || list.chatIds != allowlist?.chatIds
        allowlist = list
        syncUnsupported = false
        builder.prefilter = .synced(list)
        do { try list.save(to: syncedConfigURL) } catch { Log.warn("could not cache synced allowlist: \(error)") }
        if changed {
            Log.info("allowlist synced: v\(list.settingsVersion) (\(list.handles.count) handle(s), \(list.chatIds.count) chat(s))")
        }
        holdLogged = false
        await sendWakeup.signal()
        if changed { await syncAvatars() }  // new people → their photos
    }

    /// GET /api/agent/config and apply it. Returns true on success. No-op when sync is off.
    @discardableResult
    public func syncAllowlist() async -> Bool {
        guard config.syncAllowlist else { return false }
        do {
            await applyRemoteConfig(try await client.fetchAgentConfig())
            return true
        } catch let e as BrainError where e.status == 404 {
            if !syncUnsupported {
                Log.warn("brain has no /api/agent/config (older version); using local allow_handles until it does")
                syncUnsupported = true
                builder.prefilter = .local
                await sendWakeup.signal()
            }
            return false
        } catch {
            Log.warn("allowlist sync failed: \(error)\(allowlist.map { "; keeping cached v\($0.settingsVersion)" } ?? "")")
            return false
        }
    }

    /// Send-time decision for the outbox head.
    enum SendDecision { case send, hold, drop }

    func sendDecision(for item: BufferedEvent) -> SendDecision {
        guard usesSyncedFilter else { return .send }  // local prefilter already applied at scan time
        guard let list = allowlist else { return .hold }
        return list.allows(handle: item.event.senderHandle, chatIdentifier: item.chatIdentifier,
                           chatGUID: item.event.chatId) ? .send : .drop
    }

    // MARK: Database / checkpoint

    /// Opens chat.db if needed and probes it. Updates the Full Disk Access flag.
    @discardableResult
    func ensureDatabase() -> MessagesDatabase? {
        if let db = messagesDB {
            do {
                try db.probe()
                fdaOK = true
                return db
            } catch {
                noteDBError("chat.db probe failed: \(error)")
                messagesDB = nil
            }
        }
        do {
            let db = try MessagesDatabase(path: config.chatDBURL.path, readOnly: true,
                                          nsUnarchiverFallback: config.useNSUnarchiverFallback)
            try db.probe()
            messagesDB = db
            fdaOK = true
            if lastDBError != nil {
                Log.info("chat.db is readable again")
                lastDBError = nil
            }
            return db
        } catch {
            fdaOK = false
            noteDBError("cannot read \(config.chatDBURL.path) — grant Full Disk Access to the agent binary (\(error))")
            return nil
        }
    }

    private func noteDBError(_ msg: String) {
        if lastDBError != msg { Log.error(msg) }
        lastDBError = msg
    }

    private func ensureCheckpoint(_ db: MessagesDatabase) throws {
        guard !checkpointReady else { return }
        if let n = backfill {
            let start = try db.rowidForBackfill(count: n)
            try checkpoint.initialize(rowid: start)
            Log.info("backfill: resending the last \(n) messages (from ROWID > \(start))")
        } else if !checkpoint.exists {
            let start = try db.maxRowid()
            try checkpoint.initialize(rowid: start)
            Log.info("first run: starting after current max ROWID \(start) (no history backfill)")
        } else {
            Log.info("resuming after ROWID \(checkpoint.scanPosition) (acked \(checkpoint.lastRowid), buffered \(buffer.count))")
        }
        checkpointReady = true
    }

    // MARK: Scanning

    /// Reads new rows, appends sendable ones to the buffer and advances the scan position.
    /// Returns the number of events buffered.
    @discardableResult
    public func scan() -> Int {
        guard let db = ensureDatabase() else { return 0 }
        var total = 0
        do {
            try ensureCheckpoint(db)
            while true {
                let rows = try db.messages(after: checkpoint.scanPosition, limit: 200)
                guard let lastRow = rows.last else { break }
                var batch: [BufferedEvent] = []
                for row in rows {
                    switch builder.decide(row, context: []) {
                    case .skip(let reason):
                        Log.debug("skip ROWID \(row.rowid): \(reason)")
                    case .send(var event):
                        if let chat = row.chatRowid {
                            let ctx = (try? db.context(chatRowid: chat, before: row.rowid, limit: config.contextCount)) ?? []
                            event.recentContext = builder.formatContext(ctx)
                        }
                        batch.append(BufferedEvent(rowid: row.rowid, event: event, chatIdentifier: row.chatIdentifier))
                    }
                }
                try buffer.append(batch)
                try checkpoint.markScanned(lastRow.rowid)
                if buffer.isEmpty { try checkpoint.markAcked(lastRow.rowid) }
                total += batch.count
                if !batch.isEmpty { Log.info("queued \(batch.count) event(s) up to ROWID \(lastRow.rowid)") }
                if rows.count < 200 { break }
            }
        } catch {
            Log.error("scan failed: \(error)")
        }
        return total
    }

    // MARK: Delivery

    /// Delivers buffered events in order. Returns true when the buffer is empty (or only
    /// permanently rejected events were dropped), false when delivery should be retried later.
    public func flush() async -> Bool {
        guard !isFlushing else { return true }
        isFlushing = true
        defer { isFlushing = false }
        while let head = buffer.first {
            switch sendDecision(for: head) {
            case .hold:
                if !holdLogged {
                    Log.info("holding \(buffer.count) event(s) until the allowlist is synced from the brain")
                    holdLogged = true
                }
                return true  // nothing deliverable now; a successful sync wakes the sender
            case .drop:
                // Never log the handle or text of a non-allowlisted message.
                Log.info("dropping ROWID \(head.rowid): not on the synced allowlist")
                if !advancePast(head) { return false }
                continue
            case .send:
                break
            }
            let outcome = await client.postEvent(head.event)
            switch outcome {
            case .consumed(let status):
                Log.info("event \(head.event.eventId) → \(status)")
            case .rejected(let why):
                Log.error("event \(head.event.eventId) rejected by brain, skipping: \(why)")
            case .unauthorized:
                Log.error("brain rejected the agent token (401/403); keeping \(buffer.count) event(s) buffered")
                return false
            case .retryLater(let why):
                Log.warn("brain unreachable (\(why)); \(buffer.count) event(s) buffered")
                return false
            }
            if !advancePast(head) { return false }
        }
        return true
    }

    /// Pops `head` from the outbox and advances the acked checkpoint. Returns false on I/O failure.
    private func advancePast(_ head: BufferedEvent) -> Bool {
        do {
            guard buffer.first?.event.eventId == head.event.eventId else { return true }
            try buffer.popFirst()
            if let next = buffer.first {
                try checkpoint.markAcked(next.rowid - 1)
            } else {
                try checkpoint.markAcked(max(head.rowid, checkpoint.scanPosition))
            }
            return true
        } catch {
            Log.error("failed to update outbox/checkpoint: \(error)")
            return false
        }
    }

    // MARK: Commands

    /// One long-poll round: fetch commands, execute each, report results. Returns how many ran.
    @discardableResult
    public func handleCommands(wait: Int) async throws -> Int {
        let commands = try await client.fetchCommands(wait: wait)
        for cmd in commands {
            Log.info("command \(cmd.commandId) op=\(cmd.op) event=\(cmd.eventId ?? "-")")
            let result = await executor.execute(cmd)
            await report(cmd, result)
        }
        if !commands.isEmpty { await noteCommandsExecuted() }
        return commands.count
    }

    private func report(_ cmd: AgentCommand, _ result: CommandResult) async {
        var backoff = Backoff(base: 1, cap: 30)
        for attempt in 1...6 {
            do {
                switch try await client.postResult(commandId: cmd.commandId, result: result) {
                case .ok: return
                case .unknownCommand:
                    Log.warn("brain does not know command \(cmd.commandId); dropping result")
                    return
                }
            } catch {
                Log.warn("posting result for \(cmd.commandId) failed (attempt \(attempt)): \(error)")
                await sleepSeconds(backoff.next())
            }
        }
        // The brain re-delivers unacknowledged commands after the lease expires; the tag check
        // makes that safe.
        Log.error("giving up on result for \(cmd.commandId); brain will re-deliver it")
    }

    // MARK: Completion sync

    public enum StatusSyncResult: Equatable, Sendable {
        case disabled
        case busy
        case synced(tracked: Int, reported: Int)
        case failed(String)
    }

    public var statusSyncDisabled: Bool { statusSchedule.disabled }
    public var statusSyncInterval: TimeInterval { statusSchedule.interval }

    /// Schedules a (debounced) status sync after commands ran, so the brain hears about the result
    /// of e.g. a re-created item quickly.
    func noteCommandsExecuted(at t: Date = Date()) async {
        guard !statusSchedule.disabled else { return }
        statusSchedule.noteCommand(at: t)
        await statusWakeup.signal()
    }

    /// When the next status sync is due (nil = disabled). Exposed for tests.
    var nextStatusSync: Date? { statusSchedule.nextRun }

    /// One completion-sync round: GET tracked items, look each up, POST the reports in batches.
    @discardableResult
    public func syncItemStatus() async -> StatusSyncResult {
        guard !statusSchedule.disabled else { return .disabled }
        guard !statusSyncRunning else { return .busy }
        statusSyncRunning = true
        defer { statusSyncRunning = false }
        let tracked: TrackedList
        do {
            tracked = try await client.fetchTracked()
        } catch let e as BrainError where e.status == 404 {
            Log.warn("brain has no /api/agent/tracked (older version); completion sync off until restart")
            statusSchedule.disable()
            return .disabled
        } catch {
            statusSchedule.noteSynced()
            Log.warn("completion sync: could not fetch tracked items: \(error)")
            return .failed(String(describing: error))
        }
        statusSchedule.setInterval(tracked.intervalS)
        await store.refreshForStatusSync()
        let reports = await ItemStatusChecker(store: store).reports(for: Array(tracked.items.prefix(500)))
        var sent = 0
        do {
            var i = 0
            while i < reports.count {
                let batch = Array(reports[i..<min(i + 200, reports.count)])
                try await client.postItemStatus(batch)
                sent += batch.count
                i += 200
            }
        } catch {
            statusSchedule.noteSynced()
            Log.warn("completion sync: posting status failed after \(sent) item(s): \(error)")
            await postSnapshot()
            return .failed(String(describing: error))
        }
        statusSchedule.noteSynced()
        await postSnapshot()
        let missing = reports.filter { !$0.exists }.count
        let done = reports.filter { $0.completed == true }.count
        Log.debug("completion sync: \(tracked.items.count) tracked, \(sent) reported (\(done) completed, \(missing) missing)")
        return .synced(tracked: tracked.items.count, reported: sent)
    }

    // MARK: Calendar snapshot

    public enum SnapshotResult: Equatable, Sendable {
        case disabled
        /// Nothing readable (no permission / store not loaded): nothing posted, brain keeps its data.
        case skipped
        case posted(events: Int?, reminders: Int?)
        case failed(String)
    }

    public var snapshotPostingDisabled: Bool { snapshotDisabled }

    /// Posts everything on the user's calendars and reminder lists for the next few days. Runs with
    /// every completion sync (same cadence, including the debounced run after commands).
    @discardableResult
    public func postSnapshot(now: Date = Date()) async -> SnapshotResult {
        guard !snapshotDisabled else { return .disabled }
        let parts = await store.calendarSnapshot(rangeDays: snapshotRangeDays, now: now)
        guard !parts.isEmpty else { return .skipped }
        let snapshot = CalendarSnapshot(parts: parts, generatedAt: AppleDate.iso8601(now),
                                        rangeDays: snapshotRangeDays)
        do {
            try await client.postSnapshot(snapshot)
        } catch let e as BrainError where e.status == 404 {
            Log.warn("brain has no /api/agent/snapshot (older version); calendar snapshot off until restart")
            snapshotDisabled = true
            return .disabled
        } catch {
            Log.warn("calendar snapshot failed: \(error)")
            return .failed(String(describing: error))
        }
        Log.debug("calendar snapshot: \(snapshot.events?.count.description ?? "–") event(s), \(snapshot.reminders?.count.description ?? "–") reminder(s)")
        return .posted(events: snapshot.events?.count, reminders: snapshot.reminders?.count)
    }

    // MARK: Contact photos

    public enum AvatarSyncResult: Equatable, Sendable {
        case disabled
        case skipped(String)
        /// Same names and photos as the last successful post.
        case unchanged
        case posted(Int)
        case failed(String)
    }

    public var avatarPostingDisabled: Bool { avatarsDisabled }

    /// Sends the watched people's contact names and photos when they changed since the last post.
    @discardableResult
    public func syncAvatars(force: Bool = false) async -> AvatarSyncResult {
        guard !avatarsDisabled else { return .disabled }
        guard !avatarSyncRunning else { return .skipped("already running") }
        guard usesSyncedFilter, let list = allowlist else { return .skipped("no synced allowlist") }
        guard await contacts.isAuthorized() else { return .skipped("no Contacts access") }
        avatarSyncRunning = true
        defer { avatarSyncRunning = false }
        let cards: [ContactCard]
        do {
            cards = try await contacts.contacts(matching: list.handles)
        } catch {
            Log.warn("reading contacts failed: \(error)")
            return .failed(String(describing: error))
        }
        let people = AvatarMatcher.people(for: list.handles, contacts: cards)
        let fingerprint = AvatarMatcher.fingerprint(people)
        if !force, AvatarState.load(from: avatarStateURL)?.fingerprint == fingerprint { return .unchanged }
        do {
            try await client.postAvatars(people)
        } catch let e as BrainError where e.status == 404 {
            Log.warn("brain has no /api/agent/avatars (older version); contact photos off until restart")
            avatarsDisabled = true
            return .disabled
        } catch {
            Log.warn("posting contact photos failed: \(error)")
            return .failed(String(describing: error))
        }
        do {
            try AvatarState(fingerprint: fingerprint, postedAt: AppleDate.iso8601(Date())).save(to: avatarStateURL)
        } catch {
            Log.warn("could not save avatar state: \(error)")
        }
        let withPhoto = people.filter { $0.image != nil }.count
        Log.info("contact photos: sent \(people.count) person(s), \(withPhoto) with a photo")
        return .posted(people.count)
    }

    private func avatarLoop() async {
        while !Task.isCancelled {
            await sleepSeconds(24 * 3600)
            await syncAvatars()
        }
    }

    private func statusSyncLoop() async {
        while !Task.isCancelled {
            guard let due = statusSchedule.nextRun else { return }  // disabled (older brain)
            let wait = due.timeIntervalSinceNow
            if wait > 0 {
                await statusWakeup.wait(timeout: wait)
                await statusWakeup.drain()
                continue  // re-evaluate: a command may have moved the due time earlier
            }
            await syncItemStatus()
        }
    }

    // MARK: Heartbeat

    public func makeHeartbeat() async -> Heartbeat {
        _ = ensureDatabase()
        let perms = await store.permissionFlags()
        return Heartbeat(
            lastRowid: checkpoint.lastRowid,
            fdaOk: fdaOK,
            remindersOk: perms.reminders,
            calendarOk: perms.calendar,
            uptimeS: Int(Date().timeIntervalSince(startedAt)),
            bufferedEvents: buffer.count,
            allowlistVersion: allowlistVersion,
            allowlistSize: allowlistSize,
            reminderkitOk: await organizer.lastKnownAvailability(),
            contactsOk: await contacts.isAuthorized()
        )
    }

    public func sendHeartbeat() async throws {
        let ack = try await client.heartbeat(await makeHeartbeat())
        if config.syncAllowlist, let v = ack.settingsVersion, v != allowlist?.settingsVersion || syncUnsupported {
            await syncAllowlist()
        }
    }

    // MARK: Loops

    private func scanLoop() async {
        let wakeup = scanWakeup
        let sendWakeup = self.sendWakeup
        let w = FileWatcher(paths: [config.chatDBURL.path, config.chatDBURL.path + "-wal"]) {
            Task { await wakeup.signal() }
        }
        w.start()
        watcher = w
        var lastRearm = Date()
        while !Task.isCancelled {
            if scan() > 0 { await sendWakeup.signal() }
            await wakeup.wait(timeout: config.pollIntervalS)
            // Debounce bursts of WAL writes.
            await sleepSeconds(0.5)
            await wakeup.drain()
            // Periodically re-arm watchers in case chat.db-wal was recreated while we missed it.
            if Date().timeIntervalSince(lastRearm) > 600 {
                w.start()
                lastRearm = Date()
            }
        }
        w.stop()
    }

    private func sendLoop() async {
        var backoff = Backoff(base: 2, cap: 300)
        while !Task.isCancelled {
            if await flush() {
                backoff.reset()
                await sendWakeup.wait(timeout: 60)
            } else {
                await sleepSeconds(backoff.next())
            }
        }
    }

    private func commandLoop() async {
        var backoff = Backoff(base: 2, cap: 120)
        while !Task.isCancelled {
            do {
                try await handleCommands(wait: config.longPollWaitS)
                backoff.reset()
            } catch {
                let delay = backoff.next()
                Log.warn("command poll failed: \(error); retrying in \(Int(delay))s")
                await sleepSeconds(delay)
            }
        }
    }

    private func heartbeatLoop() async {
        var lastFailureLogged = false
        while !Task.isCancelled {
            do {
                try await sendHeartbeat()
                if lastFailureLogged { Log.info("heartbeat delivered again") }
                lastFailureLogged = false
            } catch {
                if !lastFailureLogged { Log.warn("heartbeat failed: \(error)") }
                lastFailureLogged = true
            }
            await sleepSeconds(config.heartbeatIntervalS)
        }
    }

    /// Fallback refresh in case a heartbeat-driven sync is missed.
    private func configSyncLoop() async {
        while !Task.isCancelled {
            await sleepSeconds(600)
            await syncAllowlist()
        }
    }

    /// Runs forever.
    public func run() async {
        Log.info("mac-agent \(AgentInfo.version) starting; brain=\(config.brainURL) chat.db=\(config.chatDBURL.path)")
        // Cheap probe (classes + selectors only) so the first heartbeat reports reminderkit_ok.
        let rk = await organizer.isAvailable()
        Log.info("ReminderKit sections/tags: \(rk ? "available" : "unavailable — reminders that ask for a section or tags use the title fallback")")
        if config.syncAllowlist {
            if let a = allowlist { Log.info("using cached allowlist v\(a.settingsVersion) until the brain answers") }
            await syncAllowlist()
        }
        if !(await contacts.isAuthorized()) {
            let ok = await contacts.requestAccess()
            Log.info("Contacts access (for the watched people's photos): \(ok ? "granted" : "not granted — photos off")")
        }
        await syncAvatars()
        await withTaskGroup(of: Void.self) { group in
            if self.config.syncAllowlist { group.addTask { await self.configSyncLoop() } }
            group.addTask { await self.scanLoop() }
            group.addTask { await self.sendLoop() }
            group.addTask { await self.commandLoop() }
            group.addTask { await self.heartbeatLoop() }
            group.addTask { await self.statusSyncLoop() }
            group.addTask { await self.avatarLoop() }
        }
    }

    /// Single pass for debugging (`--once`).
    public func runOnce() async {
        _ = await organizer.isAvailable()
        if config.syncAllowlist { await syncAllowlist() }
        let queued = scan()
        Log.info("once: queued \(queued) event(s)")
        let delivered = await flush()
        Log.info("once: buffer \(delivered ? "flushed" : "NOT fully flushed") (\(buffer.count) left)")
        do {
            let n = try await handleCommands(wait: 0)
            Log.info("once: executed \(n) command(s)")
        } catch {
            Log.error("once: command poll failed: \(error)")
        }
        let statusResult = await syncItemStatus()
        Log.info("once: completion sync (+ calendar snapshot) → \(statusResult)")
        let avatarResult = await syncAvatars()
        Log.info("once: contact photos → \(avatarResult)")
        do {
            try await sendHeartbeat()
            Log.info("once: heartbeat sent")
        } catch {
            Log.error("once: heartbeat failed: \(error)")
        }
    }
}
