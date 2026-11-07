import Foundation
import GRDB
import ResearchContracts

public actor ResearchDatabase {
    private let db: DatabaseQueue
    public init(path: String) throws {
        var config = Configuration(); config.prepareDatabase { db in try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON") }
        db = try DatabaseQueue(path: path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
            CREATE TABLE research(id TEXT PRIMARY KEY, revision INTEGER NOT NULL, payload BLOB NOT NULL);
            CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, researchID TEXT NOT NULL REFERENCES research(id), payload BLOB NOT NULL);
            CREATE TABLE outbox(key TEXT PRIMARY KEY, researchID TEXT NOT NULL REFERENCES research(id), manifestHash TEXT NOT NULL, payload BLOB NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE contracts(researchID TEXT NOT NULL REFERENCES research(id), version INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(researchID,version));
            """)
        }
        migrator.registerMigration("v2.evidence") { db in
            try db.execute(sql: """
            CREATE TABLE artifacts(researchID TEXT NOT NULL REFERENCES research(id), hash TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(researchID,hash));
            CREATE TABLE evidence_edges(researchID TEXT NOT NULL, source TEXT NOT NULL, target TEXT NOT NULL, relation TEXT NOT NULL,
                PRIMARY KEY(researchID,source,target,relation),
                FOREIGN KEY(researchID,source) REFERENCES artifacts(researchID,hash),
                FOREIGN KEY(researchID,target) REFERENCES artifacts(researchID,hash));
            """)
        }
        migrator.registerMigration("v3.invocations") { db in
            try db.execute(sql: "CREATE TABLE invocations(id TEXT PRIMARY KEY, researchID TEXT NOT NULL REFERENCES research(id), payload BLOB NOT NULL)")
        }
        try migrator.migrate(db)
    }
    public func create(_ contract: ResearchContract) throws -> ResearchSnapshot {
        try contract.profile.validate()
        let state = ResearchSnapshot(contract: contract)
        try db.write { db in
            let active = try Data.fetchAll(db, sql: "SELECT payload FROM research").map { try Codec.decode(ResearchSnapshot.self, from: $0) }
                .filter { $0.phase != .finished && $0.operation != .cancelled }
            guard active.count < 4 else { throw NormaError.forbidden("Four active topics maximum") }
            try db.execute(sql: "INSERT INTO research VALUES (?,?,?)", arguments: [state.id.uuidString, 0, try Codec.encode(state)])
            try db.execute(sql: "INSERT INTO contracts VALUES (?,?,?)", arguments: [state.id.uuidString, contract.version, try Codec.encode(contract)])
        }
        return state
    }
    public func list() throws -> [ResearchSnapshot] {
        try db.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM research ORDER BY rowid DESC").map { try Codec.decode(ResearchSnapshot.self, from: $0) } }
    }
    public func snapshot(_ id: UUID) throws -> ResearchSnapshot {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM research WHERE id=?", arguments: [id.uuidString]) else { throw NormaError.invalid("Unknown research") }
            return try Codec.decode(ResearchSnapshot.self, from: data)
        }
    }
    @discardableResult
    public func update(_ state: ResearchSnapshot, expected: Int, kind: String, detail: String,
                       dispatch: (key: String, hash: String, payload: Data)? = nil,
                       artifacts: [EvidenceArtifact] = [], edges: [EvidenceEdge] = [], invocation: AgentCheckpoint? = nil) throws -> ResearchSnapshot {
        try db.write { db in
            guard try Int.fetchOne(db, sql: "SELECT revision FROM research WHERE id=?", arguments: [state.id.uuidString]) == expected else { throw NormaError.conflict }
            if let saved = try Data.fetchOne(db, sql: "SELECT payload FROM contracts WHERE researchID=? AND version=?", arguments: [state.id.uuidString, state.contract.version]) {
                let previous = try Codec.decode(ResearchContract.self, from: saved)
                var incoming = state.contract
                // JSON millisecond dates can lose sub-microsecond floating-point precision.
                guard abs(incoming.createdAt.timeIntervalSince(previous.createdAt)) < 0.001 else { throw NormaError.forbidden("Contract creation time changed") }
                incoming.createdAt = previous.createdAt
                guard previous == incoming else { throw NormaError.forbidden("Contract versions are immutable") }
            }
            if state.phase != .finished && state.operation != .cancelled {
                let others = try Data.fetchAll(db, sql: "SELECT payload FROM research WHERE id!=?", arguments: [state.id.uuidString])
                    .map { try Codec.decode(ResearchSnapshot.self, from: $0) }
                    .filter { $0.phase != .finished && $0.operation != .cancelled }
                guard others.count < 4 else { throw NormaError.forbidden("Four active topics maximum") }
            }
            var updated = state; updated.revision = expected + 1
            var event = AuditEvent(researchID: state.id, kind: kind, detail: detail)
            try db.execute(sql: "INSERT INTO events(id,researchID,payload) VALUES (?,?,?)", arguments: [event.id.uuidString, state.id.uuidString, try Codec.encode(event)])
            event.sequence = db.lastInsertedRowID; updated.eventSequence = event.sequence
            try db.execute(sql: "UPDATE events SET payload=? WHERE sequence=?", arguments: [try Codec.encode(event), event.sequence])
            updated.events.append(event)
            if updated.events.count > 200 { updated.events.removeFirst(updated.events.count - 200) }
            if let dispatch {
                if let row = try Row.fetchOne(db, sql: "SELECT researchID,manifestHash FROM outbox WHERE key=?", arguments: [dispatch.key]) {
                    guard row["manifestHash"] as String == dispatch.hash, row["researchID"] as String == state.id.uuidString else { throw NormaError.forbidden("Idempotency key rebound") }
                } else {
                    try db.execute(sql: "INSERT INTO outbox(key,researchID,manifestHash,payload) VALUES (?,?,?,?)", arguments: [dispatch.key, state.id.uuidString, dispatch.hash, dispatch.payload])
                }
            }
            for artifact in artifacts {
                guard artifact.researchID == state.id else { throw NormaError.forbidden("Cross-topic evidence") }
                try db.execute(sql: "INSERT OR IGNORE INTO artifacts VALUES (?,?,?)",
                    arguments: [state.id.uuidString, artifact.hash, try Codec.encode(artifact)])
            }
            for edge in edges {
                try db.execute(sql: "INSERT OR IGNORE INTO evidence_edges VALUES (?,?,?,?)",
                    arguments: [state.id.uuidString, edge.sourceHash, edge.targetHash, edge.relation])
            }
            if let invocation {
                guard invocation.researchID == state.id else { throw NormaError.forbidden("Cross-topic invocation") }
                try db.execute(sql: "INSERT INTO invocations VALUES (?,?,?)", arguments: [invocation.id.uuidString, state.id.uuidString, try Codec.encode(invocation)])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO contracts VALUES (?,?,?)", arguments: [state.id.uuidString, state.contract.version, try Codec.encode(state.contract)])
            try db.execute(sql: "UPDATE research SET revision=?,payload=? WHERE id=?", arguments: [updated.revision, try Codec.encode(updated), updated.id.uuidString])
            return updated
        }
    }
    public func events(after sequence: Int64) throws -> [AuditEvent] {
        try db.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM events WHERE sequence>? ORDER BY sequence LIMIT 500", arguments: [sequence]).map { try Codec.decode(AuditEvent.self, from: $0) } }
    }
    public func acknowledge(_ key: String) throws {
        try db.write { try $0.execute(sql: "UPDATE outbox SET acknowledged=1 WHERE key=?", arguments: [key]) }
    }
    public func pending() throws -> [Data] { try db.read { try Data.fetchAll($0, sql: "SELECT payload FROM outbox WHERE acknowledged=0") } }
    public func backup(to path: String) throws { try db.backup(to: DatabaseQueue(path: path)) }
    public func close() throws { try db.close() }
    public func artifacts(_ researchID: UUID) throws -> [EvidenceArtifact] {
        try db.read { try Data.fetchAll($0, sql: "SELECT payload FROM artifacts WHERE researchID=? ORDER BY hash", arguments: [researchID.uuidString])
            .map { try Codec.decode(EvidenceArtifact.self, from: $0) } }
    }
    public func edges(_ researchID: UUID) throws -> [EvidenceEdge] {
        try db.read { db in try Row.fetchAll(db, sql: "SELECT source,target,relation FROM evidence_edges WHERE researchID=? ORDER BY source,target", arguments: [researchID.uuidString])
            .map { EvidenceEdge(sourceHash: $0["source"], targetHash: $0["target"], relation: $0["relation"]) } }
    }
    public func checkpoint(_ checkpoint: AgentCheckpoint) throws {
        try db.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM invocations WHERE id=?", arguments: [checkpoint.id.uuidString]) else { throw NormaError.invalid("Invocation was not admitted") }
            let old = try Codec.decode(AgentCheckpoint.self, from: data)
            guard old.researchID == checkpoint.researchID, old.role == checkpoint.role, old.model == checkpoint.model,
                  old.threadID == nil || old.threadID == checkpoint.threadID else { throw NormaError.forbidden("Invocation checkpoint identity changed") }
            var updated = checkpoint
            updated.tokenUsage = checkpoint.tokenUsage ?? old.tokenUsage
            try db.execute(sql: "UPDATE invocations SET payload=? WHERE id=?", arguments: [try Codec.encode(updated), checkpoint.id.uuidString])
        }
    }
    public func invocations() throws -> [AgentCheckpoint] {
        try db.read { try Data.fetchAll($0, sql: "SELECT payload FROM invocations").map { try Codec.decode(AgentCheckpoint.self, from: $0) } }
    }
}
