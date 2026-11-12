# ADR-0002: Local-first storage with SwiftData and an outbox

**Status:** Proposed
**Date:** 2026-11-11
**Deciders:** Liam

## Context
Bow must work fully offline and with no server at all. When a Grimmory account is connected, Bow mirrors a library
that may hold thousands of books, and queues user changes until it can push them. The reader kit lets the host app
supply its own storage (`DCReaderCoordsProtocol`, or `DCHighlightStoreProtocol` + `DCReadingPositionStoreProtocol`).

## Decision
Use **SwiftData** as the single local store for the catalog and user state, write sync work to an **outbox table in
the same transaction**, and keep book files on disk (not in the database). Implement the kit's store protocols on
top of SwiftData, and don't use `DCJSONReaderStore`.

## Options Considered

### Option A: SwiftData + outbox
| Dimension | Assessment |
|---|---|
| Complexity | Low–Med |
| Cost | None, it's built in |
| Scalability | Fine for ~10k books with indexed fields and batched upserts on a `@ModelActor` |
| Team familiarity | High, works with SwiftUI `@Query` |

**Pros:** `@Query` drives the UI directly. No extra dependency. CloudKit is possible later.
**Cons:** Less control over SQL and migrations. Bulk upserts need care.

### Option B: GRDB (SQLite)
| Dimension | Assessment |
|---|---|
| Complexity | Med |
| Cost | Third-party dependency |
| Scalability | Excellent, full SQL and FTS5 search |
| Team familiarity | Medium |

**Pros:** Fast bulk sync, FTS, precise migrations.
**Cons:** More glue for SwiftUI observation. Another dependency to track.

### Option C: Core Data
**Pros:** Mature, with batch insert.
**Cons:** More boilerplate than SwiftData for no real gain on a 27.x deployment target.

## Trade-off Analysis
Bow's data is moderate in size and very UI-driven, which is where SwiftData is strongest. The main risk is
bulk-sync speed. That risk is contained by doing upserts on a background `@ModelActor` in batches, keyed on
`remoteId`. If profiling with a large library shows problems, GRDB can replace the store behind `BowModel` without
touching the UI much.

## Consequences
- Easier: offline UI for free, one source of truth, simple reader integration.
- Harder: schema migrations need `VersionedSchema` discipline from day one.
- Revisit: performance with a 10k-book library. Search may need its own index (Spotlight or FTS).

## Action Items
1. [ ] Define `VersionedSchema` v1 with the entities in architecture.md §3.
2. [ ] Implement `SwiftDataReaderStore: DCHighlightStoreProtocol, DCReadingPositionStoreProtocol`, writing a `PendingChange` on every write.
3. [ ] Add a seed script/test that creates 10k books to profile list and sync performance.
