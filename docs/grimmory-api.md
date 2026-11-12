# Grimmory API — what Bow uses

**Source read:** `grimmory-tools/grimmory` @ `c80ce81` (2026-11-11), a shallow clone, read only and not built.
**Backend:** Spring Boot (Java 25), package `org.booklore`. The **web reader** is foliate-js, vendored at
`frontend/src/assets/foliate`.

The repo exposes 346 routes in 65 controllers. This doc covers the ones Bow needs, plus where to find the rest.

## Getting the full OpenAPI spec

Grimmory doesn't publish its API docs, but the code is fully annotated with springdoc (`@Operation`, `operationId`,
`@Tag`), so a complete spec exists at runtime:

| Way | How | Notes |
|---|---|---|
| **Running server** (recommended) | Start Grimmory with `API_DOCS_ENABLED=true` | Spec at `GET /api/openapi.json`, Scalar UI at `/api/docs`. Use a dev/test instance. |
| **Nightly CI artifact** | `publish-nightly.yml` uploads `grimmory-openapi.json` as a GitHub Actions artifact | Needs `gh run download`. Artifacts expire. |
| **Build it** | `./gradlew exportOpenApi` in `backend/` (JDK 25) | Boots the backend with the `openapi-export` profile. |

ADR-0004 stands: generate the client from that spec. This doc is the map of which parts matter.

### The nightly spec (checked 2026-11-11)

Artifact `openapi-nightly-20261111-37ccdf4df` from run `42957057003`, version `nightly-20261111-37ccdf4df`,
SHA-256 `d72f643f…a9d4865`.

- **Contents:** OpenAPI **3.1.0**, with 313 paths, 404 operations and 289 schemas. Every operation has an
  `operationId`.
- **Checked against this doc:** every concrete endpoint listed here is in the spec. The key request and response
  schemas (`AccessTokenDto`, `AppPageResponseAppBookSummary`, `AppBookProgressResponse`, `BookFileProgress`,
  `CreateAnnotationRequest`, `BookMark`) match what's described above.
- **Stability:** `info.description` warns that the API is **unstable**. Expect changes, and pin the spec version
  Bow generates from.
- **License:** `info.license` is **AGPL-3.0**, the same as Grimmory. See open question 7 in `architecture.md`
  before copying it into Bow's repo.

Spring quirks that need a patch step before running swift-openapi-generator:

| Quirk | Fix |
|---|---|
| Responses use `*/*` as the content type, which the generator treats as raw bytes | Rewrite `*/*` to `application/json` for every response that has a JSON schema |
| No `securitySchemes`, so the generator won't add auth | The `GrimmoryClient` middleware adds `Authorization: Bearer` |
| `servers` is the CI machine's `http://127.0.0.1:<port>` | Pass the user's server URL at runtime |
| `UpdateProgressRequest` has a bogus `progressValid` property (from an `@AssertTrue` getter) | Drop it from the schema |
| Downloads are typed `StreamingResponseBody` | Leave them out of generation, and hand-write downloads on a background `URLSession` |
| Most schemas list no `required` fields | Accept everything as optional, and validate in the DTO → domain mapping |
| A few operation IDs have Spring suffixes (`downloadBook_2`) | Rename via the generator's `filter` + typeOverrides, or ignore |

## Two API layers

1. **`/api/v1/app/*` (the app API).** Endpoints written for native clients (`@Tag "App Books"`: "the app
   experience"). They're lean, paginated, and cover browsing, progress, status, rating and the notebook. **Bow's
   primary read/sync surface.**
2. **`/api/v1/*` (the web app's API).** Everything else: shelf editing, annotations, bookmarks, metadata,
   uploads, email, stats, admin. Bow uses these for the "do what the web can do" features.

Legacy/other protocols, which Bow doesn't use: OPDS (`/api/v1/opds`, `/api/v2/opds`), KOReader sync
(`/api/koreader`), Kobo (`/api/kobo/{token}`), and a Komga-compatible API (`/komga/api`).

## Auth

Grimmory has four ways in, and Bow supports all of them (`GrimmoryClient`, in `BowKit/Sources/GrimmoryAPI`).
Every one ends with the same Grimmory access and refresh tokens.

| Method | When | Grimmory calls | `GrimmoryClient` |
|---|---|---|---|
| **First-run setup** | `GET /api/v1/setup/status` → `data: false` (no users yet) | `POST /api/v1/setup` `{username, name, email, password}`, then password login | `serverInfo().needsSetup`, `createFirstAdmin(…)` |
| **Password** | Unless the admin forces OIDC-only | `POST /api/v1/auth/login` `{username, password}` | `signIn(username:password:)` |
| **OIDC** | `public-settings.oidcEnabled` | `GET /api/v1/auth/oidc/state`, the provider's authorize endpoint, then `POST /api/v1/auth/oidc/mobile/callback?code&code_verifier&redirect_uri&nonce&state` | `beginOIDCSignIn(provider:)`, `completeOIDCSignIn(_:callbackURL:)` |
| **Remote (proxy) auth** | `public-settings.remoteAuthEnabled` | `GET /api/v1/auth/remote`, with the reverse proxy adding the user headers | `signInWithRemoteAuth()` |

Before any of them, `GET /api/v1/public-settings` (no auth) returns
`{remoteAuthEnabled, oidcEnabled, oidcForceOnlyMode, oidcProviderDetails{providerName, clientId, issuerUri, scopes}}`.
`serverInfo()` turns that into what the sign-in screen needs.

### OIDC

Bow's flow matches the web app's (`frontend/.../oidc.service.ts`), using Grimmory's native-app callback:

1. **State:** `GET /oidc/state` returns a one-time `state` issued by the server.
2. **Authorize URL:** the `authorization_endpoint` comes from `<issuer>/.well-known/openid-configuration`. The URL
   carries:
   - `response_type=code`, `client_id`, and `redirect_uri=grimmory://oauth2-callback`
   - `scope`, which defaults to `openid profile email groups offline_access` like the web app
   - `code_challenge` (S256) and the `state`
   - a random `nonce`, which Grimmory checks in the ID token
3. **Sign-in:** the app opens that URL with `ASWebAuthenticationSession`, listening for callback scheme
   `grimmory`. It's non-ephemeral, so an existing provider session gives single sign-on. The returned URL goes
   to `completeOIDCSignIn`.
4. **Callback checks:** `completeOIDCSignIn` checks that `state` matches and surfaces provider errors
   (`error_description`). It then posts the code and verifier to `/oidc/mobile/callback`, and Grimmory exchanges
   the code with the provider using its client secret.

Setup requirements on the server side:
- **Allowed redirects:** Grimmory accepts native redirect URIs from its allowlist, which defaults to
  **`grimmory://oauth2-callback`** (plus legacy `booklore://oauth2-callback`). Admins can add more, or `*`.
  `ASWebAuthenticationSession` catches the scheme itself, so Bow never registers `grimmory://` system-wide.
- **Provider client:** the identity provider's client must also allow that redirect URI. A Grimmory already set
  up for its mobile apps has it. If it isn't allowed, the provider shows its own error page and the sign-in
  sheet never returns.
- **Not used:** `GET /oidc/redirect` (which sends tokens back in a URL fragment through `app_redirect_uri`) and
  `POST /oidc/callback` (web origin only).

### Remote (proxy) auth

The admin puts a reverse proxy (Authelia, Authentik, oauth2-proxy, …) in front of Grimmory. The proxy signs the
user in and adds `Remote-User`-style headers, and `GET /auth/remote` turns those headers into Grimmory tokens. The
web app calls it at startup.

A native app only gets through the proxy with the proxy's session cookie. So Bow's flow will be:
1. Open the server in a `WKWebView` sheet so the user signs in to the proxy.
2. Copy the proxy's cookies for that host into the `URLSession` that `GrimmoryClient` uses.
3. Call `signInWithRemoteAuth()`.

If remote auth is off, that call returns 403 (`.forbidden`).

Any API call that comes back as a web page throws **`GrimmoryError.webPageInsteadOfAPI`**. That usually means the
proxy's session expired and it answered with its login page, because URLSession follows the redirect. The app
shows the proxy sheet again. This also covers servers that sit behind an auth proxy while using password or OIDC
sign-in, unless the proxy exempts `/api/`.

### Tokens and sign-out

| Call | Notes |
|---|---|
| `POST /api/v1/auth/refresh` | `{refreshToken}` → new `AccessTokenDto` |
| `POST /api/v1/auth/logout` | `{refreshToken}` → `{logoutUrl?}`. For OIDC users, `logoutUrl` is the provider's end-session URL, which Bow can open to end the provider session too. `signOut()` returns it and always clears local tokens. |
| `PUT /api/v1/users/change-password` | `{currentPassword, newPassword}`. Used when `isDefaultPassword` is true at login (`GrimmoryUser.hasDefaultPassword`); the web app forces this. |
| `GET /api/v1/users/me` | Current user with the **full** permission set (`BookLoreUser`). Bow uses this one. |
| `GET /api/v1/app/users/me` | Only `admin`, `canUpload`, `canDownload`, `canAccessBookdrop` and `maxFileUploadSizeMb`. Too little for gating the UI. |

- **Lifetimes:** the access token lasts **2 hours** (`expires` is a lifetime in seconds). The refresh token lasts
  **30 days**.
- **Refresh tokens rotate.** Each refresh revokes the old token, so `GrimmorySession` **single-flights**
  refreshes. A rejected refresh signs the user out, while a network failure keeps the tokens.
- **Sending the token:** `Authorization: Bearer <accessToken>`. Media, download and EPUB-streaming paths also
  accept `?token=`. Bow still uses the header, because tokens in URLs end up in logs.
- **Live revocation:** the WebSocket queue `/queue/session-revoked` reports when a session is revoked.

### Permissions (gate the UI with these)

From `BookLoreUser.UserPermissions`, among others:

| Permission | Gates |
|---|---|
| `isAdmin` | everything |
| `canDownload` | downloads (**offline reading**) |
| `canUpload` | uploading |
| `canEditMetadata` | metadata editing |
| `canEmailBook` | send by email |
| `canDeleteBook` | deleting books |
| `canAccessBookdrop` | the Bookdrop inbox |
| `canAccessUserStats` | personal reading stats |
| `canAccessLibraryStats` | library stats |
| `canManageLibrary` | library management |

> **`canDownload` matters most.** Without it, `GET /books/{id}/download` returns 403, so Bow can't keep that
> user's books offline. Respect it: show such books as online-only, or unavailable, rather than rebuilding the
> file from the EPUB streaming endpoints.

## Catalog (app API)

| Call | Notes |
|---|---|
| `GET /api/v1/app/libraries` | Libraries the user can see |
| `GET /api/v1/app/books` | `AppPageResponse<AppBookSummary>`. **Page size is capped at 50.** Takes a `BookListRequest` as query params. |
| `GET /api/v1/app/books/ids` | **All** matching IDs, unpaginated. Use it to detect deletions. |
| `GET /api/v1/app/books/{id}` | `AppBookDetail` |
| `GET /api/v1/app/books/search?q=` | Free-text search |
| `GET /api/v1/app/books/continue-reading` | Home screen rows |
| `GET /api/v1/app/books/recently-added` | Home screen rows |
| `GET /api/v1/app/books/random` | Home screen rows |
| `GET /api/v1/app/filter-options` | Facet values for the filter UI |
| `GET /api/v1/app/authors` | Author browsing |
| `GET /api/v1/app/authors/{id}` | One author |
| `GET /api/v1/app/series` | Series browsing |
| `GET /api/v1/app/series/{name}/books` | Books in one series |
| `GET /api/v1/app/shelves` | Manual shelves |
| `GET /api/v1/app/shelves/magic` | Magic shelves |
| `GET /api/v1/app/shelves/magic/{id}/books` | Server-evaluated magic shelf membership |

- **Paging and filters:** `BookListRequest` takes `page, size, sort, dir`, `libraryId, shelfId, magicShelfId`, and
  `search`. About 35 multi-value filters (status, fileType, authors, series, tag, …) combine with
  `filterMode` = `or` / `and` / `not`.
- **Summary fields:** `AppBookSummary` has `id, title, authors, thumbnailUrl, readStatus, personalRating,
  seriesName/Number, libraryId, addedOn, lastReadTime, readProgress, primaryFileId/Type/Name, coverUpdatedOn`,
  plus metadata fields.
- **No "changed since" filter, and no metadata `updatedAt`.** A full sync means paging everything (200 requests
  for 10k books) and diffing by a hash of each summary. Make the full sync rare, and use WebSocket events and
  targeted refetches for the rest. `coverUpdatedOn` drives cover cache invalidation.

## Files and covers

| Call | Notes |
|---|---|
| `GET /api/v1/books/{id}/download` | Primary file. Needs `canDownload`. |
| `GET /api/v1/books/{id}/files/{fileId}/download` | A specific format or file |
| `GET /api/v1/books/{id}/files` | List of a book's files and formats |
| `GET /api/v1/media/book/{id}/thumbnail` | Thumbnail image |
| `GET /api/v1/media/book/{id}/cover` | Full cover image |

- **No resume:** downloads stream back as a `StreamingResponseBody` with **no HTTP Range support**. Bow's download
  manager must restart failed downloads from zero, and resume data won't help.

## Reading progress

| Call | Shape |
|---|---|
| `GET /api/v1/app/books/{id}/progress` | Returns `readProgress, readStatus, lastReadTime` and `epubProgress {cfi, href, percentage, updatedAt}`. Also `pdfProgress {page, percentage, updatedAt}`, `cbxProgress` and `koreaderProgress {percentage, device, deviceId, lastSyncTime}`. |
| `PUT /api/v1/app/books/{id}/progress` | `{fileProgress: {bookFileId, positionData, positionHref, progressPercent, ttsPositionCfi?, contentSourceProgressPercent?}, dateFinished?}` |
| `PUT /api/v1/app/books/{id}/status` | Read status |
| `PUT /api/v1/app/books/{id}/rating` | Personal rating |

- **Which field to send:** `fileProgress` is current. The per-format `epubProgress`/`pdfProgress` fields in the
  request are `@Deprecated`.
- **What `positionData` holds:** for EPUB it's the **CFI**. For PDF and comics it's the page number as a string.
- **ADR-0003 confirmed:** progress interop with the web reader is CFI + percentage.
- **KOReader progress:** this is a separate field. Bow can show it ("KOReader on Kobo: 43%") but shouldn't write it.

## Annotations, notes, bookmarks

Grimmory keeps three separate resources. The kit has one `DCHighlight` with `type` H / N / B.

| Grimmory | Endpoints | Fields | Kit mapping |
|---|---|---|---|
| **Annotation** | `GET /api/v1/annotations/book/{bookId}`, `POST /api/v1/annotations`, `PUT /api/v1/annotations/{id}`, `DELETE /api/v1/annotations/{id}` | `id, bookId, cfi (≤1000), text (≤5000), color (#RRGGBB), style (highlight/underline/strikethrough/squiggly), note (≤5000), chapterTitle, createdAt, updatedAt` | `H` highlights, and `N` notes (a highlight with `note`) |
| **Bookmark** | `GET /api/v1/bookmarks/book/{bookId}`, `POST /api/v1/bookmarks`, `PUT /api/v1/bookmarks/{id}`, `DELETE /api/v1/bookmarks/{id}` | `id, bookId, cfi, pageNumber, positionMs, trackIndex, title, color, notes, priority, …` | `B` |
| **Book note v2** | `GET /api/v2/book-notes/book/{bookId}`, `POST /api/v2/book-notes`, `PUT /api/v2/book-notes/{id}`, `DELETE /api/v2/book-notes/{id}` | `id, bookId, cfi, selectedText, noteContent, color, chapterTitle` | Show read-only at first (see open questions) |
| Notebook | `GET /api/v1/app/notebook/books`, `GET /api/v1/app/notebook/books/{id}/entries` | All of the above across books | "Notebook" screen |

What Bow has to handle:
- **IDs:** server IDs are `Long`, and the server doesn't accept a client ID. Bow keeps its own `uuid` and stores
  `remoteId` once `POST` returns. A `PendingChange` for an unsynced annotation's update or delete must wait for
  its create.
- **Timestamps:** `createdAt`/`updatedAt` are `LocalDateTime`, with **no time zone**. Only compare server
  timestamps with other server timestamps. Never compare them with device clocks for last-write-wins.
- **Colors:** the web palette is yellow `#FACC15`, green `#4ADE80`, blue `#38BDF8`, pink `#F472B6` and orange
  `#FB923C`, plus darker variants. The kit has `yellow, green, blue, pink, purple, underline`. Map the first four
  one-to-one, and `underline` to `style: underline`. **Purple has no web equivalent, and orange has no kit
  equivalent.** See kit follow-up #14.
- **Styles:** the web's `strikethrough` and `squiggly` styles have no kit style. Show them as a plain highlight in
  the annotation's color, and keep the original style when writing back.
- **PDF annotations:** separate `GET/PUT/DELETE /api/v1/pdf-annotations/book/{bookId}`, a whole-document blob per book.

## Shelves, metadata, and other web features

| Feature | Endpoints |
|---|---|
| Shelves CRUD | `GET /api/v1/shelves`, `POST /api/v1/shelves`, `GET /api/v1/shelves/{id}`, `PUT /api/v1/shelves/{id}`, `DELETE /api/v1/shelves/{id}`, `GET /api/v1/shelves/{id}/books` |
| Add/remove books on shelves | `POST /api/v1/books/shelves` (`ShelvesAssignmentRequest`) |
| Magic shelves | `GET /api/magic-shelves`, `GET /api/magic-shelves/{id}`, `POST /api/magic-shelves` (create or update), `DELETE /api/magic-shelves/{id}`. Note: no `/v1/`. |
| Edit metadata | `PUT /api/v1/books/{id}/metadata` |
| Search providers | `POST /api/v1/books/{id}/metadata/prospective` |
| Provider detail | `GET /api/v1/books/metadata/detail/{provider}/{itemId}` |
| ISBN lookup | `POST /api/v1/books/metadata/isbn-lookup` |
| Bulk edit | `PUT /api/v1/books/bulk-edit-metadata` |
| Metadata review tasks | `/api/metadata/tasks/*` |
| Covers | `BookCoverController` under `/api/v1/books` |
| Upload | `FileUploadController` under `/api/v1/files` |
| Bookdrop inbox | `/api/v1/bookdrop/*` |
| Send by email | `POST /api/v1/email/book/{bookId}` (quick), `POST /api/v1/email/book` |
| Email recipients | `/api/v1/email/recipients` |
| Reading sessions | `POST /api/v1/reading-sessions`. Bow should record these, as they feed the stats. |
| Stats | `/api/v1/user-stats/reading/*` (heatmap, streak, speed, genres, timeline…), `/api/v1/user-stats/listening/*` |
| Reviews | `/api/v1/reviews` |
| Recommendations | `GET /api/v1/books/{id}/recommendations` |
| Duplicates | `POST /api/v1/books/duplicates` |
| Viewer settings | `GET/PUT /api/v1/books/{id}/viewer-setting` (per-book reader settings, a candidate for syncing) |
| Custom fonts | `/api/v1/custom-fonts`. Can be fed into the kit's extra-fonts configuration. |
| Server info | `GET /api/v1/version`, `GET /api/v1/healthcheck` (use as the "add server" probe) |
| Admin | users, libraries, tasks, audit log, OIDC group mappings, OPDS/Kobo/KOReader users, settings. Use "Open in web" first. |

Grimmory also does **audiobooks** (`/api/v1/audiobooks`, continue-listening, listening stats). That's out of
scope for Bow v1, but the model shouldn't rule it out.

## Live updates (WebSocket)

STOMP over WebSocket at `/ws` (`WebSocketConfig`). The per-user queues Bow cares about:

| Queue | Bow action |
|---|---|
| `/queue/book-add` | Refetch and insert |
| `/queue/book-update` | Refetch that book |
| `/queue/book-metadata-update` | Refetch that book |
| `/queue/books-remove` | Mark removed |
| `/queue/books-cover-update` | Invalidate the cover |
| `/queue/session-revoked` | Sign out, keep local files |

Use it only while the app is in the foreground (`URLSessionWebSocketTask` plus minimal STOMP framing). Background
sync stays on `BGAppRefreshTask` and paging.

## CFI compatibility notes

- The web reader takes the spine step from the book's **real OPF** (`foliate/epub.js`:
  `CFI.fromElements($$itemref)`). The streaming loader does the same. Only foliate's `fake.fromIndex` hardcodes
  `/6`, and Grimmory doesn't use it.
- So the kit's hardcoded `/6` (kit follow-up #12) **does** differ from Grimmory for books whose `<spine>` isn't the
  third child of `<package>`.
- The kit strips book scripts before laying out the page, while foliate keeps the original DOM. In-body `<script>`
  elements shift element indices (kit follow-up #13).
- The server has its own CFI utilities (`util/koreader/EpubCfiService`, which converts KOReader XPointers to CFI).
  They're useful as a reference implementation for tests.
