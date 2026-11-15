// The script's one thread of control. Socket frames, timers and child-process
// output all arrive in a mailbox; this loop drains it, one thing at a time, so
// script code never runs concurrently with itself.
//
//   reader thread ─┐
//   exec threads  ─┼─► mailbox ─► pump ─┬─► ingest ─► events ─► handlers
//   SIGINT        ─┘                    ├─► timers
//                                       └─► request/reply (never dispatches)
//
// pump(dispatch:) is the only knob: sleep, wait and the idle loop allow handlers
// and timers to run; a request forbids them, so a handler can't fire between a
// command and its answer and send one of its own.

import Foundation
import Common

enum Wake {
    case frame(Frame)
    case hangup
    case interrupt
    // Runs on the loop thread as soon as it's drained: bookkeeping only.
    case post(() -> Void)
}

// Whether a pump may run handlers and timers while it waits.
enum Dispatch {
    case allow, forbid
}

enum PumpEnd {
    case done, timeout, hangup
}

enum Expect {
    case created(String)        // paneCreated echoing this reqID
    case groupCreated(String)
    case dump(PaneID)
    case tie(String)
    case exit(PaneID)           // paneExit as a waitPane answer
    case barrier                // the layout reply that ends a fire-and-forget
}

private final class Pending {
    let expect: Expect
    var reply: Frame?
    var failure: String?
    var done = false

    init(_ expect: Expect) { self.expect = expect }

    // True when the frame was this request's answer and nothing else's.
    func offer(_ f: Frame) -> Bool {
        if f.tag == .errorReply, let e: ErrorReply = f.decode() {
            return refuse(e)
        }

        switch expect {
        case .created(let id):
            guard f.tag == .paneCreated, let m: PaneCreated = f.decode(), m.reqID == id else { return false }

            finish(f)
            return false
        case .groupCreated(let id):
            guard f.tag == .groupCreated, let m: GroupCreated = f.decode(), m.reqID == id else { return false }

            finish(f)
            return false
        case .tie(let id):
            guard f.tag == .tieMeta, let m: TieMeta = f.decode(), m.id == id else { return false }

            finish(f)
            return false
        case .dump(let id):
            guard f.tag == .paneDump, let m: PaneDump = f.decode(), m.id == id else { return false }

            finish(f)
            return true
        case .exit(let id):
            guard f.tag == .paneExit, let m: PaneExit = f.decode(), m.id == id else { return false }

            finish(f)
            return true
        case .barrier:
            guard f.tag == .welcome || f.tag == .paneList else { return false }

            finish(f)
            return true
        }
    }

    private func finish(_ f: Frame) {
        reply = f
        done = true
    }

    // An error answers us unless it names someone else's create.
    private func refuse(_ e: ErrorReply) -> Bool {
        switch expect {
        case .created(let id) where e.reqID != nil && e.reqID != id:
            return false
        case .barrier:
            // The layout reply still follows; it ends the exchange.
            failure = failure ?? e.message
            return true
        default:
            failure = e.message
            done = true
            return true
        }
    }
}

final class LoopTimer {
    let id: Int
    let interval: TimeInterval?
    fileprivate(set) var due: Date
    fileprivate(set) var active = true
    fileprivate let fire: () -> Void

    fileprivate init(id: Int, delay: TimeInterval, interval: TimeInterval?, fire: @escaping () -> Void) {
        self.id = id
        self.interval = interval
        self.due = Date().addingTimeInterval(delay)
        self.fire = fire
    }
}

final class ScriptLoop {
    static let maxTimers = 1024
    private static let askTimeout: TimeInterval = 30
    private static let eventCap = 4096

    let session: ScriptSession

    // Handlers running right now: dispatch waits until this is back to zero.
    private var depth = 0
    private var seq = 0
    private var hungUp = false

    private let box = Mailbox()
    private var events = [ScriptEvent]()
    private var jobs = [() -> Void]()
    private var timers = [Int: LoopTimer]()
    private var nextTimerID = 1
    private var pending: Pending?
    private var signals: DispatchSourceSignal?

    // The Lua side: what a ready event does, and what ^C does.
    var onEvent: (ScriptEvent) -> Void = { _ in }
    var onInterrupt: () -> Void = {}

    init(session: ScriptSession) {
        self.session = session
    }

    var inHandler: Bool { depth > 0 }

    func start() {
        session.startReader { [box] f in
            box.put(f.map(Wake.frame) ?? .hangup)
        }

        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { [box] in box.put(.interrupt) }
        src.resume()
        signals = src
    }

    func post(_ w: Wake) {
        box.put(w)
    }

    // Runs when nothing else is ahead of it, outside any pump that forbids it.
    func enqueue(_ job: @escaping () -> Void) {
        jobs.append(job)
    }

    // Jobs already queued (stream output) run now, so a wait that saw the end
    // of a command has also delivered everything it printed.
    func flush() {
        while depth == 0, !jobs.isEmpty {
            runInHandler(jobs.removeFirst())
        }
    }

    // MARK: Timers

    var timerCount: Int { timers.count }

    func addTimer(after delay: TimeInterval, every interval: TimeInterval?, fire: @escaping () -> Void) -> LoopTimer? {
        guard timers.count < Self.maxTimers else { return nil }

        let t = LoopTimer(id: nextTimerID, delay: delay, interval: interval, fire: fire)
        nextTimerID += 1
        timers[t.id] = t
        return t
    }

    func cancel(_ id: Int) {
        timers[id]?.active = false
        timers[id] = nil
    }

    func isActive(_ id: Int) -> Bool {
        timers[id]?.active ?? false
    }

    // MARK: Events

    // First buffered event the predicate likes, taken out of handlers' reach.
    func takeEvent(where match: (ScriptEvent) -> Bool) -> ScriptEvent? {
        // Over a copy: the predicate may run script code that buffers more.
        guard let hit = events.first(where: match) else { return nil }
        guard let i = events.firstIndex(where: { $0.seq == hit.seq }) else { return nil }

        return events.remove(at: i)
    }

    private func buffer(_ batch: [ScriptEvent]) {
        for var e in batch {
            seq += 1
            e.seq = seq

            // A burst of layout changes is one change as far as anyone can tell.
            if e.name == Evt.viewChanged, events.last?.name == Evt.viewChanged {
                events[events.count - 1] = e
                continue
            }

            events.append(e)
        }

        if events.count > Self.eventCap {
            events.removeFirst(events.count - Self.eventCap)
        }
    }

    // MARK: Requests

    // Send, then block for the matching answer. Nothing else runs meanwhile.
    @discardableResult
    func request(_ expect: Expect, send: () throws -> Void) throws -> Frame? {
        let p = Pending(expect)
        pending = p
        defer { pending = nil }

        try send()

        let end = pump(until: Date().addingTimeInterval(Self.askTimeout), dispatch: .forbid) { p.done }
        switch end {
        case .done: break
        case .timeout: throw ScriptError("daemon did not answer")
        case .hangup: throw ScriptError("daemon went away")
        }

        if let why = p.failure { throw ScriptError(why) }
        return p.reply
    }

    // A command with no answer of its own: ask for the layout right behind it,
    // so a refusal (an errorReply) lands before we move on.
    func act(_ send: () throws -> Void) throws {
        try request(.barrier) {
            try send()
            try session.askLayout()
        }
    }

    // MARK: Pump

    @discardableResult
    func pump(until limit: Date? = nil, dispatch: Dispatch, done: () -> Bool) -> PumpEnd {
        while true {
            if done() { return .done }

            let canRun = dispatch == .allow && depth == 0
            if canRun, runReady() { continue }
            if hungUp { return .hangup }

            let now = Date()
            if let limit, now >= limit { return .timeout }

            var wakeAt = limit
            if canRun, let due = timers.values.map(\.due).min() {
                wakeAt = wakeAt.map { min($0, due) } ?? due
            }

            guard let w = box.take(until: wakeAt) else { continue }

            handle(w)
        }
    }

    private func handle(_ w: Wake) {
        switch w {
        case .hangup:
            hungUp = true
        case .interrupt:
            onInterrupt()
        case .post(let work):
            work()
        case .frame(let f):
            let consumed = pending?.offer(f) ?? false
            guard !consumed else { return }

            buffer(session.ingest(f))
        }
    }

    // One ready callback: a job, an event, or a due timer. False when idle.
    private func runReady() -> Bool {
        if !jobs.isEmpty {
            runInHandler(jobs.removeFirst())
            return true
        }
        if !events.isEmpty {
            let e = events.removeFirst()
            runInHandler { self.onEvent(e) }
            return true
        }

        let now = Date()
        guard let t = timers.values.filter({ $0.due <= now }).min(by: { $0.due < $1.due }) else { return false }

        reschedule(t, now: now)
        runInHandler(t.fire)
        return true
    }

    // Ticks missed while busy are dropped: the next one is the next future slot.
    private func reschedule(_ t: LoopTimer, now: Date) {
        guard let step = t.interval else {
            timers[t.id] = nil
            return
        }

        var next = t.due.addingTimeInterval(step)
        if next <= now {
            let missed = (now.timeIntervalSince(next) / step).rounded(.down) + 1
            next = next.addingTimeInterval(missed * step)
        }
        t.due = next
    }

    private func runInHandler(_ work: () -> Void) {
        depth += 1
        work()
        depth -= 1
    }
}

// Blocking queue with a deadline.
private final class Mailbox: @unchecked Sendable {
    private let cond = NSCondition()
    private var items = [Wake]()

    func put(_ w: Wake) {
        cond.lock()
        items.append(w)
        cond.signal()
        cond.unlock()
    }

    // The next item, or nil once `limit` passes (nil limit waits for ever).
    func take(until limit: Date?) -> Wake? {
        cond.lock()
        defer { cond.unlock() }

        while items.isEmpty {
            guard let limit else {
                cond.wait()
                continue
            }
            guard cond.wait(until: limit) else { break }
        }

        return items.isEmpty ? nil : items.removeFirst()
    }
}
