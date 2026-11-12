# Bow — Architecture Plan

**Status:** Draft · **Date:** 2026-11-11

Bow is a local-first e-reader for iPhone, iPad and Mac. It works fully on its own (import files, read, highlight).
It can also connect to a **Grimmory** server: it mirrors your library, keeps chosen books offline, and syncs
progress, annotations, shelves and metadata both ways. The goal is that the Grimmory web app can do almost nothing
that Bow can't.

EPUB rendering is handled by **DCEpubReaderKit** (fork: `github.com/netliam/DCEpubReaderKit`).

> ⚠️ **Verify:** I wrote the Grimmory API and feature details from what I know of its BookLore lineage
> (Spring Boot backend, Angular web app, JWT auth, OPDS/KOReader/Kobo endpoints). None of it was checked against
> Grimmory's current source or OpenAPI spec. Step 1 of Phase 1 is to pull the spec and correct this doc.

---

## 1. Principles

1. **Local-first.** The on-device database is the source of truth for the UI. The network only feeds it.
   Every screen works offline.
2. **Server optional.** "No server" is a supported mode. Grimmory is an *account* the user adds.
3. **Reader-agnostic app.** The library, sync and UI never import DCEpubReaderKit directly. They go through one
   small `ReaderAdapter` boundary so PDF/comics and kit changes stay isolated.
4. **Outbox for writes.** Every user change (progress, highlight, rating, shelf edit) is written locally first,
   with a pending-sync record next to it. A sync engine pushes those records when it can.

---

## 2. Module layout

One local Swift package (`BowKit/`) holding several targets, plus the app target. That's enough separation to
test sync without UI, without the overhead of many packages.

```
Bow (app target, SwiftUI)            ← screens, navigation, platform glue
 └─ BowKit (local package)
     ├─ BowModel        ← SwiftData models + domain types (Book, Shelf, Annotation, Progress, Account)
     ├─ GrimmoryAPI     ← HTTP client, auth, DTOs. No SwiftData, no UI. Pure + testable.
     ├─ BowSync         ← SyncEngine: pull catalog, push outbox, download manager, conflict rules
     ├─ BowLibrary      ← local import, file storage, cover cache, search index
     └─ BowReaders      ← ReaderAdapter protocol + EPUB (DCEpubReaderKit), PDF (PDFKit), CBZ (later)
```

Dependency direction: `App → BowReaders/BowSync/BowLibrary → BowModel`, `BowSync → GrimmoryAPI`.
`GrimmoryAPI` depends on nothing.

### Data flow

```
 Grimmory server ──REST──▶ GrimmoryAPI ──DTOs──▶ BowSync ──upsert──▶ SwiftData (BowModel)
                                                   ▲                       │ @Query
                         outbox (PendingChange) ───┘                       ▼
                                                                    SwiftUI views
                                                                           │ open book
 Book files on disk ◀── DownloadManager (background URLSession)            ▼
   AppSupport/Books/<accountId>/<bookId>/file.epub              ReaderAdapter (EPUB/PDF)
                                                                           │ progress, highlights
                                                                           ▼
                                                              SwiftData + PendingChange
```

---

## 3. Data model (BowModel)

| Entity | Key fields | Notes |
|---|---|---|
| `Account` | id, serverURL, username, kind (`.grimmory` / `.local`) | Tokens live in the **Keychain**, never in SwiftData. One local account always exists. |
| `Book` | id (local UUID), accountId, remoteId?, title, authors, series, seriesIndex, formats, fileHash, metadata blob, coverPath | `remoteId` is nil for local-only imports. |
| `BookFile` | bookId, format (epub/pdf/cbz), remoteFileId?, localPath?, size, downloadState | A book can have several formats. |
| `ReadingProgress` | bookId, locator, percentage, updatedAt, deviceId | `locator` is defined in ADR-0003. |
| `Annotation` | uuid, bookId, kind (highlight/note/bookmark), locator, text, note, style, created/updated/deletedAt | Soft-delete (tombstone) so deletes sync. |
| `Shelf` | id, remoteId?, name, kind (`.manual` / `.magic(rules)`), icon | Magic shelves are evaluated on the server; Bow caches the membership it's sent. |
| `ReadStatus`, `Rating` | per book | Small user-state fields, synced. |
| `PendingChange` | id, entity, entityId, op, payload, attempts, lastError | The outbox. |

`DCEpubBook.uniqueIdentifier` (from the OPF) is **not** used as Bow's book key. Two server books can share an OPF
id, and some books have none. The reader adapter maps Bow's `Book.id` ⇄ the kit's `bookId`.

---

## 4. Grimmory feature parity

Target: everything a regular user can do in the web app. Admin-only server setup is lower priority, and a
"Open in web" fallback covers it at first.

| Area | Web capability (verify) | Bow plan | Phase |
|---|---|---|---|
| Auth | Username/password (JWT + refresh), OIDC | Native login; OIDC via `ASWebAuthenticationSession` | 1 |
| Browse | Libraries, grid/list, sort, filter, search | Native, works offline from cache | 1 |
| Book detail | Metadata, covers, formats, series, authors | Native | 1 |
| Download / offline | Download file | Per-book "Keep offline", plus per-shelf auto-download | 1 |
| Reading progress | Synced per book/format | Two-way, see ADR-0003 | 1 |
| Read status & rating | Unread/reading/read, stars | Two-way | 1 |
| Shelves | Manual shelves | Create/edit/add/remove, two-way | 2 |
| Magic shelves | Rule-based shelves | Show (server-evaluated); edit rules in phase 3 | 2/3 |
| Annotations | Highlights, notes, bookmarks in web reader | Two-way, needs locator mapping | 2 |
| Metadata edit | Edit fields, fetch from providers, upload cover | Native editor; provider search through server | 3 |
| Upload / Bookdrop | Upload files to library | Share sheet + Files import → upload | 3 |
| Send to device/email | Kindle/email delivery | Call server endpoint | 3 |
| Stats | Reading stats | Show server stats + local reading sessions | 3 |
| Series / authors views | Browse by series/author | Native | 2 |
| Admin (users, libraries, scanners, OPDS/Kobo/KOReader settings) | Admin panels | "Open in web" first; native later if worth it | 4 |
| Other readers | PDF, comics (CBZ/CBR) | PDFKit for PDF (phase 2), image reader for CBZ (phase 3) | 2/3 |

---

## 5. Sync design (BowSync)

- **Catalog pull:** on launch, on foreground, on pull-to-refresh, and in a `BGAppRefreshTask`. Use incremental
  "changed since" queries if the API has them. Otherwise page through everything and diff by `remoteId` + updated
  timestamp. Books missing from the server get marked removed, and their local files stay until the user deletes them.
- **Outbox push:** a `PendingChange` is written in the same SwiftData transaction as the change itself. The engine
  drains it in order, retrying with exponential backoff. A 4xx error parks the change and shows it in a
  "Sync issues" view instead of looping.
- **Conflicts:**
  - Progress: furthest-read wins if it's within a few minutes of the other device's update, otherwise latest
    `updatedAt` wins. Show "Jump to page X from iPad?" when the server is ahead of an open book.
  - Annotations: merge by `uuid`. Last-write-wins per annotation. Tombstones beat edits older than them.
  - Metadata/shelves: server wins, unless a local edit is still pending.
- **Downloads:** background `URLSession` with resume data. Files go to `Application Support/Books/…`, which is
  excluded from backup, since the server can supply them again. Local imports are the exception and stay backed up.
- **Concurrency:** `SyncEngine` is an `actor`. It writes through a `@ModelActor` and never touches the main context.

---

## 6. Reader integration (BowReaders)

```swift
protocol ReaderAdapter {
    associatedtype Content: View
    func makeReader(book: Book, file: URL, start: Locator?, events: ReaderEvents) -> Content
}
// ReaderEvents: progressChanged(Locator, percentage), annotationSaved, annotationDeleted
```

- **EPUB:** `EpubAdapter` implements `DCHighlightStoreProtocol` + `DCReadingPositionStoreProtocol`, backed by
  SwiftData, behind `DCStoreReaderDelegate(store:bookId:)`. It does **not** use `DCJSONReaderStore`, so there's one
  store and one outbox. It passes a `DCReaderConfiguration` (as of kit `0.1.0`) with Bow's `bookId`, `onClose`
  (closes the Mac reader window), and `onOpenExternalURL`. At sync time it converts positions and highlights with
  `DCCFIConverter`.
- **PDF:** `PDFKit` (`PDFView`), which works natively on iOS and macOS. Its locator is the page index plus a
  selection range.
- **Reader preferences:** the kit stores them in `UserDefaults.standard`. Fine for now, and it could later move
  to an iCloud key-value store to sync themes across devices.

### Changes needed in the fork

Bow needs changes in DCEpubReaderKit itself. They're tracked separately in
[dcepubreaderkit-changes.md](dcepubreaderkit-changes.md), so work on the kit doesn't get mixed up with work on Bow.

---

## 7. App structure & UI

- **iPad / Mac:** `NavigationSplitView`. Sidebar: Library, Reading Now, Shelves, Series, Authors, Downloads, and the
  server's libraries. Content: grid/list. Detail: book page. The reader opens full-screen (iPad) or in its own
  window (Mac, via `openWindow`).
- **iPhone:** `TabView` (Reading Now · Library · Shelves · Search · Settings).
- State: Observation (`@Observable`) view models, `@Query` for lists, environment-injected `SyncEngine` and
  `AccountStore`.
- Settings: Accounts (add Grimmory server), Downloads & storage, Reader defaults, Sync issues.

---

## 8. Project setup fixes

| # | Issue found | Status |
|---|---|---|
| 1 | The package rule `1.0.0..<2.0.0` matched no tag (the fork had none) | ✅ Pinned to `0.1.0` up to next minor (`0.1.x`). Pre-1.0 minor bumps may break the API. |
| 2 | The `DCEpubReaderKit` product wasn't linked to the `Bow` target | ✅ Linked |
| 3 | The kit is iOS-only, but Bow targeted native `macosx` | ✅ iPhone + iPad + Mac Catalyst (`TARGETED_DEVICE_FAMILY 1,2,6`) |
| 4 | visionOS (`xros`) was in `SUPPORTED_PLATFORMS` | ✅ Removed |
| 5 | No outgoing-network entitlement for the sandboxed Mac build | ✅ `ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES` (only checked once a signed build exists) |
| 6 | Self-hosted servers are often plain `http://` on a LAN | ✅ `Config/Info.plist` with `NSAllowsLocalNetworking`, plus `NSLocalNetworkUsageDescription`. Public hosts and Tailscale `*.ts.net` names still need HTTPS. |
| 7 | `SWIFT_VERSION` was 5.0 | ✅ 6.0 |
| 8 | The scheme was named `MyApp` | ✅ Renamed to `Bow` |
| 9 | The template `#Playground` broke the Catalyst build | ✅ Wrapped in `#if canImport(Playgrounds)` |
| 10 | The bundle id is still `devplaceholder.…` | ⏳ Set a real id before adding iCloud, App Groups or background tasks |
| 11 | Deployment target is 27.2 (latest OS only) | ⏳ Confirm |

---

## 9. Roadmap

**Phase 0 — Foundation (setup fixes above)**
- BowKit package skeleton, SwiftData container, Keychain wrapper, CI build for iOS + Mac.

**Phase 1 — Read and stay in sync (MVP)**
- Pull Grimmory's OpenAPI spec and verify §4. Generate or hand-write `GrimmoryAPI` (ADR-0004).
- Local import (Files, share sheet, drag-and-drop on Mac) and EPUB reading via `EpubAdapter`.
- Add a server, log in, browse, book detail, download/offline, progress + read-status sync.

**Phase 2 — Personal library**
- Shelves, magic-shelf display, series/authors, annotations sync (with CFI work in the fork), PDF reader.

**Phase 3 — Library management**
- Metadata editing + provider fetch, upload, send-to-device, stats, comic reader, magic-shelf editing.

**Phase 4 — Polish & admin**
- Widgets (Reading Now), Spotlight indexing, Handoff between devices, native admin screens if needed.

---

## 10. Open questions

1. **Grimmory source/spec:** is there a local checkout or a running server whose `/v3/api-docs` (or equivalent)
   I can read? Everything in §4 depends on it.
2. **Mac approach:** Catalyst (recommended, ADR-0001) or port the kit to AppKit?
3. **Local-only device sync:** should users without a server get iCloud sync between their own devices? SwiftData +
   CloudKit is possible but adds model constraints (all fields optional, no unique constraints). Recommendation:
   not in v1.
4. **Multiple servers:** the model supports several accounts, but should v1 UI allow more than one? Recommendation:
   one in v1.

## ADRs

- [ADR-0001: Mac via Catalyst for v1](adr/0001-mac-via-catalyst.md)
- [ADR-0002: Local-first storage with SwiftData and an outbox](adr/0002-local-first-swiftdata.md)
- [ADR-0003: Reading locations as EPUB CFI](adr/0003-locator-cfi.md)
- [ADR-0004: Grimmory client from the OpenAPI spec](adr/0004-grimmory-client.md)
