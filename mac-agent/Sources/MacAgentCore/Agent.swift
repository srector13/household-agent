import Foundation

/// Orchestrates the agent: watches chat.db, delivers events through the offline buffer, executes
/// commands from the brain and sends heartbeats. All mutable state is isolated to this actor.
public actor Agent {
    public let config: AgentConfig
    private let client: BrainClient
    private let store: ItemStore
    private let executor: CommandExecutor
    private let checkpoint: Checkpoint
    private let buffer: OfflineBuffer
    private let builder: EventBuilder
    private let backfill: Int?
    private let startedAt = Date()

    private var messagesDB: MessagesDatabase?
    private var fdaOK = false
    private var checkpointReady = false
    private var isFlushing = false
    private var watcher: FileWatcher?
    private var lastDBError: String?

    private let scanWakeup = Wakeup()
    private let sendWakeup = Wakeup()

    public init(config: AgentConfig, client: BrainClient, store: ItemStore,
                stateURL: URL = AgentPaths.state, bufferURL: URL = AgentPaths.buffer,
                backfill: Int? = nil, timeZone: TimeZone = .current) {
        self.config = config
        self.client = client
        self.store = store
        self.executor = CommandExecutor(store: store)
        self.checkpoint = Checkpoint(url: stateURL)
        self.buffer = OfflineBuffer(url: bufferURL)
        self.builder = EventBuilder(config: config, timeZone: timeZone)
        self.backfill = backfill
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
                        batch.append(BufferedEvent(rowid: row.rowid, event: event))
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
            do {
                guard buffer.first?.event.eventId == head.event.eventId else { continue }
                try buffer.popFirst()
                if let next = buffer.first {
                    try checkpoint.markAcked(next.rowid - 1)
                } else {
                    try checkpoint.markAcked(max(head.rowid, checkpoint.scanPosition))
                }
            } catch {
                Log.error("failed to update outbox/checkpoint: \(error)")
                return false
            }
        }
        return true
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
            bufferedEvents: buffer.count
        )
    }

    public func sendHeartbeat() async throws {
        try await client.heartbeat(await makeHeartbeat())
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

    /// Runs forever.
    public func run() async {
        Log.info("mac-agent \(AgentInfo.version) starting; brain=\(config.brainURL) chat.db=\(config.chatDBURL.path)")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.scanLoop() }
            group.addTask { await self.sendLoop() }
            group.addTask { await self.commandLoop() }
            group.addTask { await self.heartbeatLoop() }
        }
    }

    /// Single pass for debugging (`--once`).
    public func runOnce() async {
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
        do {
            try await sendHeartbeat()
            Log.info("once: heartbeat sent")
        } catch {
            Log.error("once: heartbeat failed: \(error)")
        }
    }
}
