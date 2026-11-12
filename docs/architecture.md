# Bow — Architecture Plan

**Status:** Draft · **Date:** 2026-11-11

Bow is a local-first e-reader for iPhone, iPad and Mac. It works fully on its own (import files, read, highlight).
It can also connect to a **Grimmory** server: it mirrors your library, keeps chosen books offline, and syncs
progress, annotations, shelves and metadata both ways. The goal is that the Grimmory web app can do almost nothing
that Bow can't.

EPUB rendering is handled by **DCEpubReaderKit** (fork: `github.com/netliam/DCEpubReaderKit`).

> Grimmory details below were checked against its source (`grimmory-tools/grimmory` @ `c80ce81`, 2026-11-11).
> Endpoints, payloads and gotchas are in [grimmory-api.md](grimmory-api.md).

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
`GrimmoryAPI` depends on nothing in Bow.

**Built so far (Phase 0):**
- `BowModel`: SwiftData schema v1, with no shelves yet. Shelves come in Phase 2 as a schema migration.
- `GrimmoryAPI`: the generated client, plus the hand-written `GrimmoryClient`, which covers sign-in, the
  single-flight refresh, server info, the current user, and catalog paging and IDs.
- `BowSync`: `CatalogSyncer`, which pages the Grimmory catalog into SwiftData, skips unchanged books by summary
  hash, marks books gone from the server instead of deleting them, and never lets server progress overwrite a
  book read on this device. `GrimmoryAccounts` keeps **one `GrimmoryClient` per account**, because two clients
  would race the rotating refresh token.
- **App (Phase 1, first slice):**
  - **Shell:** a split view with a sidebar of "All Books" and one entry per server ("Sign Out and Remove" in its
    context menu).
  - **Library:** a cover grid with progress bars and pull to refresh. Covers are cached on disk by
    `coverUpdatedOn`, and concurrent requests for the same cover share one download.
  - **Add Server:** reads the server's sign-in options and offers first-run setup, OIDC
    (`ASWebAuthenticationSession`), password, or proxy sign-in (a `WKWebView` that shares the proxy's cookies),
    followed by a forced password change when Grimmory requires one.
- `BowLibrary` and `BowReaders` are created when they get their first code.

The generated code lives in `GrimmoryAPI/Generated` and is committed. Regenerate it with
`Scripts/generate-grimmory-api.sh`, which patches the vendored spec, then runs swift-openapi-generator
1.14.4 from a gitignored `.build-tools/` folder. Xcode never builds or runs the generator.

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
| `Annotation` | uuid, remoteId?, bookId, kind (highlight/note/bookmark), locator, text, note, color, style, created/updated/deletedAt | Soft-delete (tombstone) so deletes sync. Grimmory keeps highlights/notes and bookmarks as separate resources with `Long` ids, so `remoteId` is filled in after the first push. |
| `Shelf` | id, remoteId?, name, kind (`.manual` / `.magic(rules)`), icon | Magic shelves are evaluated on the server; Bow caches the membership it's sent. |
| `ReadStatus`, `Rating` | per book | Small user-state fields, synced. |
| `PendingChange` | id, entity, entityId, op, payload, attempts, lastError | The outbox. |

`DCEpubBook.uniqueIdentifier` (from the OPF) is **not** used as Bow's book key. Two server books can share an OPF
id, and some books have none. The reader adapter maps Bow's `Book.id` ⇄ the kit's `bookId`.

---

## 4. Grimmory feature parity

Target: everything a regular user can do in the web app. Admin-only server setup is lower priority, and a
"Open in web" fallback covers it at first.

Every feature is gated by the user's Grimmory **permissions** (`/app/users/me`). For example, without
`canDownload` there's no offline reading at all.

| Area | Grimmory API (see grimmory-api.md) | Bow plan | Phase |
|---|---|---|---|
| Auth | `/auth/login`, `/auth/refresh` (rotating), `/auth/oidc/mobile/callback` | Native login; OIDC with PKCE via `ASWebAuthenticationSession` and `grimmory://oauth2-callback` | 1 |
| Browse | `/app/books` (50 per page, about 35 filters), `/app/filter-options`, `/app/books/search` | Native, works offline from cache | 1 |
| Home rows | `/app/books/continue-reading`, `recently-added`, `random` | "Reading Now" | 1 |
| Book detail | `/app/books/{id}`, `/books/{id}/files`, `/media/book/{id}/cover` | Native | 1 |
| Download / offline | `/books/{id}/download`, `/books/{id}/files/{fileId}/download` (no Range support) | Per-book "Keep offline", plus per-shelf auto-download | 1 |
| Reading progress | `/app/books/{id}/progress` (CFI + percentage) | Two-way (ADR-0003) | 1 |
| Read status & rating | `/app/books/{id}/status`, `/app/books/{id}/rating` | Two-way | 1 |
| Reading sessions | `/reading-sessions` | Record locally, push. Feeds server stats. | 1 |
| Shelves | `/shelves` CRUD, `/books/shelves` assignment | Two-way | 2 |
| Magic shelves | `/app/shelves/magic/{id}/books` (read), `/api/magic-shelves` (edit) | Show in phase 2, edit rules in phase 3 | 2/3 |
| Series / authors | `/app/series`, `/app/authors` | Native | 2 |
| Annotations | `/annotations`, `/bookmarks`, `/v2/book-notes`, `/app/notebook` | Two-way highlights, notes and bookmarks, plus a Notebook screen | 2 |
| Live updates | STOMP `/ws` queues | Foreground subscription | 2 |
| PDF | `/pdf-annotations` | PDFKit reader | 2 |
| Metadata edit | `/books/{id}/metadata`, `/metadata/prospective`, ISBN lookup, covers | Native editor (`canEditMetadata`) | 3 |
| Upload / Bookdrop | `/files` upload, `/bookdrop/*` | Share sheet + Files import (`canUpload`, `canAccessBookdrop`) | 3 |
| Send by email | `/email/book/{id}` | Share menu (`canEmailBook`) | 3 |
| Stats | `/user-stats/reading/*` | Stats screen with Swift Charts | 3 |
| Comics | `/media/book/{id}/cbx/pages/{n}` or download | Image reader | 3 |
| Reviews, recommendations, duplicates | `/reviews`, `/books/{id}/recommendations`, `/books/duplicates` | Book detail extras | 3 |
| Admin (users, libraries, tasks, OPDS/Kobo/KOReader, OIDC) | Admin controllers | "Open in web" first; native later if worth it | 4 |
| Audiobooks | `/audiobooks/*` | Out of scope for v1. Don't rule it out in the model. | — |

---

## 5. Sync design (BowSync)

- **Catalog pull:** Grimmory has **no "changed since" query, and no metadata `updatedAt`**. So:
  - **Full sync** (first login, then occasionally, e.g. daily or on pull-to-refresh): page `/app/books` at 50 per
    page and upsert by `remoteId`. Skip rows whose summary hash hasn't changed.
  - **Deletions:** `GET /app/books/ids` returns every ID in one call. Books missing from it are marked removed,
    and their local files stay until the user deletes them.
  - **In between:** while in the foreground, subscribe to the STOMP queues (`book-add`, `book-update`,
    `books-remove`, `books-cover-update`) and refetch just those books. In the background, a `BGAppRefreshTask`
    refreshes "continue reading" and the progress of books kept offline.
- **Outbox push:** a `PendingChange` is written in the same SwiftData transaction as the change itself. The engine
  drains it in order, retrying with exponential backoff. A 4xx error parks the change and shows it in a
  "Sync issues" view instead of looping.
- **Conflicts:**
  - Progress: furthest-read wins if it's within a few minutes of the other device's update, otherwise latest
    `updatedAt` wins. Show "Jump to page X from iPad?" when the server is ahead of an open book.
  - Annotations: match by `remoteId` (falling back to CFI + text for a first sync). Last-write-wins per
    annotation using **server** timestamps only, since Grimmory's are `LocalDateTime` with no time zone. Tombstones
    beat edits older than them. An update or delete waits for its create to return a `remoteId`.
  - Metadata/shelves: server wins, unless a local edit is still pending.
- **Auth:** access tokens last 2 hours, and refresh tokens last 30 days and **rotate** on each use.
  `GrimmoryClient` single-flights the refresh: one refresh in flight, and every other 401 waits for it. A
  `session-revoked` message or a failed refresh signs the user out but keeps downloaded files.
- **Downloads:** background `URLSession`. Grimmory has no Range support, so a failed download restarts from zero.
  Only offered when the user has `canDownload`. Files go to `Application Support/Books/…`, which is
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
- Get Grimmory's OpenAPI spec (`API_DOCS_ENABLED=true` → `/api/openapi.json`), vendor it, and generate
  `GrimmoryAPI` (ADR-0004).
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

1. ~~**Grimmory spec source**~~: resolved. The nightly CI artifact works (OpenAPI 3.1, 404 operations). See
   `grimmory-api.md`.
7. ~~**Grimmory spec license**~~: resolved 2026-11-11. The spec is AGPL-3.0, and **Bow is AGPL**, so the spec is
   vendored at `Vendor/Grimmory/grimmory-openapi.json` and the client is generated from it.
5. **Book notes v2 vs annotation notes:** Grimmory has both. Map the kit's notes to annotations with a `note`
   (recommended), and show v2 book notes read-only until it's clear how the web app uses them.
6. **Users without `canDownload`:** show their books as online-only (stream-reading would need a different reader
   path) or as unavailable? Recommendation: unavailable in v1, with an explanation.
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
