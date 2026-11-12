# DCEpubReaderKit — changes Bow needs

**Date:** 2026-11-11 · **For:** whoever is working on the DCEpubReaderKit fork

These are changes to make **in the DCEpubReaderKit repo**, not in Bow. Bow only uses them once they're merged.

## Status (2026-11-11)

Items 1–10 landed in **`0.1.0`** (`f33bfbd`). Bow is pinned to `0.1.0` "up to next minor" and builds for the iOS
Simulator and Mac Catalyst. #11 is deliberately deferred.

Differences from the spec below:
- **#6:** a single `defaults: UserDefaults` replaces the separate `preferences` + `defaults`. The preferences
  protocol is internal, and `UserDefaults` already implements it.
- **#1:** rotation lock is now per window. Hosts call `DCReaderOrientationLock.supportedOrientations(for: window)`
  from the app delegate. Bow will need a `UIApplicationDelegateAdaptor` for this once the reader is wired up.
- **#8:** the reader doesn't report a CFI on every position change. Bow converts with `DCCFIConverter` at sync time.
- **#7:** two string keys changed: "Share" → "Share…", and "(page 12)" → "(p. 12)" in exported highlights.

Not yet verified: hardware keyboard, trackpad and multi-window on a real iPad or Mac, and CFIs against output from
Grimmory itself.

### `0.2.0` (`ff23916`)

Follow-ups 12, 14 and 15 landed in **`0.2.0`**. Bow is pinned to `0.2.0` "up to next minor" and uses all three.
- **#12:** CFIs use `<spine>`'s real step from the package file (`DCEpubBook.spineStep`).
- **#14:** `DCHighlightMenuConfiguration`, with:
  - four `DCAnnotationStyle`s
  - a hex `color` on `DCHighlight`
  - palettes per style
  - ordered selection and highlight actions, and custom actions

  Bow passes Grimmory's exact palettes (`GrimmoryHighlights` in `Bow/Reader/BowReaderDelegate.swift`) and keeps
  the default actions, which already match Grimmory's.
- **#15:** `handleProgress(book:progress:)` with `DCReaderProgress` (fraction, page, total). Bow sends that
  fraction to Grimmory.

Checked in Bow's Simulator build:
- **Menu:** the selection menu shows Grimmory's five highlight colours, plus a Style submenu with underline,
  squiggly and strikethrough, each with the darker line colours.
- **Squiggly highlight:** a crimson squiggly saved as `squiggly` / `#DC143C`.
- **Progress:** page 24 of 39 reached the server as 61.54%.

### Open follow-ups

13. **Check CFIs against Grimmory.** Once Bow can talk to a real server, compare a few positions and highlights made
    in Grimmory's web reader against `DCCFIConverter` output. This covers the script-stripping difference noted in
    the `0.1.0` report.

    **Partly done (2026-11-12),** against a real Grimmory v3.5.0 (`Scripts/grimmory-dev.sh`):
    - Bow's CFI for a position in chapter 1 (`epubcfi(/6/2[c1]!/4/18)`) was stored and read back unchanged.
    - A CFI written straight to the server (`epubcfi(/6/6[c3]!/4/6)`) opened the right chapter and page.

    Still to do: compare against positions and highlights made in Grimmory's *web reader*.
16. **Progress before the book is counted.** Until the page count finishes, `DCReaderProgress.fraction` is the
    chapter estimate. Chapters differ in length, so the same page can report quite different numbers.
    - In a 3-chapter test book, page 5 of 39 reported 12.8% once counted, and 19.0% on reopening before the count
      finished.
    - Bow sends whatever arrives, so Grimmory's percentage jumps around.
    - Options:
      - Cache the page count per book and layout, so a reopen has it at once.
      - Or hold back `handleProgress` until the count is done, and let the host decide what to do with
        estimates (`page == nil`).

## Setup to know first

- **Repo:** `~/Projects/DCEpubReaderKit`
  - The fork is the **`netliam`** remote (`github.com/netliam/DCEpubReaderKit`).
  - `origin` is the original project (`novecapa`). Don't push there.
- **Version:** Bow pins the fork at **`0.2.x`** ("up to next minor" from `0.2.0`).
  - Bug fixes released as `0.2.1`, `0.2.2`… reach Bow on its next package update.
  - API changes should be tagged `0.3.0`; Bow then moves its pin deliberately.
  - The `0.0.x` tags exist only on upstream.
- **Current state:** Bow builds against `0.2.0` for the iOS Simulator and Mac Catalyst. Bow ships on Mac as
  **Mac Catalyst** for v1 (Bow's `docs/adr/0001-mac-via-catalyst.md`), so the kit can stay UIKit for now.
- **How Bow uses the kit** (so changes don't break it):
  - `DCReaderViewBuilder.build(…, delegate:, configuration:)` with `bookId`, `defaults` (suite
    `app.bow.reader`), `onClose` and `highlightMenu.palettes`.
  - A custom `DCReaderCoordsProtocol` delegate (`Bow/Reader/BowReaderDelegate.swift`), not `DCJSONReaderStore`.
    It implements `handleCoords`, `handleProgress`, and the highlight save/delete/list calls, reading
    `DCHighlight.annotationStyle` and `.color`.
  - `DCCFIConverter` for both directions, and `DCReaderOrientationLock.supportedOrientations(for:)`.
- **Checking a change:** from `~/Projects/Bow`, after pointing Bow at the new version:
  ```bash
  xcodebuild -scheme Bow -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
  xcodebuild -scheme Bow -destination 'generic/platform=macOS,variant=Mac Catalyst' build CODE_SIGNING_ALLOWED=NO
  ```

## P1 — iPad and Mac behavior

1. **Use the reader's own window scene, not "the first one".** `DCReaderOrientationLock.setLocked` and
   `DCScreenBrightness` (`Managers/DCReaderOrientationLock.swift`, `EpubViews/Settings/DCReaderSettingsView.swift`)
   take `UIApplication.shared.connectedScenes.first…`. With iPad multi-window or several Mac windows, that can
   lock or dim the wrong window. Pass the scene from the hosting view (e.g. a `UIViewRepresentable` that reads
   `view.window?.windowScene`).
2. **Hide controls that do nothing on the platform.** Rotation lock does nothing on Mac and is ignored on iPad in
   Split View or Stage Manager. Brightness does nothing on Mac. Gate them with `ProcessInfo.isMacCatalystApp` /
   size class, or let the host turn them off (see #6).
3. **Keyboard and pointer paging.** There's no key handling anywhere today (no `UIKeyCommand` / `onKeyPress`).
   Add:
   - ← / → and space / shift-space to turn pages
   - Page Up / Page Down
   - ⌘F for search
   - Esc to close
   - trackpad two-finger swipes in the pager (`EpubViews/Pager/DCPagedReaderController.swift`)
4. **Window-friendly close.** `DCReaderView` hides the navigation bar and closes via `@Environment(\.dismiss)`,
   which assumes it was pushed or presented. Add an `onClose` callback so a host that opens the reader in its own
   Mac window (`openWindow`) can close that window.
5. **Resizing.** Two-page spreads currently key off landscape. On Mac and iPad, a window resize should
   re-paginate and switch between one and two pages by *width*, not orientation.

## P2 — Make hardcoded things configurable

6. **A `DCReaderConfiguration` passed to `DCReaderViewBuilder.build`.** It would collect:
   - `preferences: DCUserPreferencesProtocol`. Today the builder hardcodes `UserDefaults.standard`
     (`EpubViews/Chapter/DCReaderViewBuilder.swift`).
   - `defaults: UserDefaults` for `DCThemeColorStore.store` (`Managers/UserPreferences/DCUserPreferencesTypes.swift`)
     and `DCHighlightStyle.store` (`EpubViews/WebView/DCWebView+Highlights.swift`). Both are
     `nonisolated(unsafe) static var … = .standard`, which is global mutable state shared across every open
     reader. Move them onto the instance.
   - `bookId: String?`, so the host can supply its own key. Today `DCReaderViewModel` and
     `DCStoreReaderDelegate` use `book.uniqueIdentifier` (from the OPF), which can collide across editions or be
     missing.
   - Feature flags: show search, line guide, rotation lock, brightness, page-curl transition.
   - `onClose` (#4), and `onOpenExternalURL`. Today `DCReaderViewModel` calls `UIApplication.shared.open(url)`
     directly.
   - Extra fonts: let the host register fonts beyond the four bundled families (`Managers/Fonts/DCFonts.swift`).
   - Keep the current behavior as the default, so existing callers don't break.
7. **Localization.** UI strings are literal `Text("Contents")` etc. in `DCContentsView`, `DCMarksView`,
   `DCReaderView`, `DCSearchView`, `DCNotesView` and `DCReaderSettingsView`. Inside a package, those look up the
   *app's* main bundle, and the package ships no string catalog. Add `Localizable.xcstrings` to `DCEpubRendering`
   and use `Text("…", bundle: .module)`.

## P3 — Sync interop

8. **CFI conversion in `EpubUtil.js`.** Add `coordsToCFI` / `cfiToCoords`, and expose them through a public API
   (or emit a CFI alongside `coords` in `handleCoords`).
   - `coords` (from `getCoordFromNode`) is already a zero-padded child-index path plus a character offset, so the
     mapping is mechanical: element steps become even CFI steps, and the text offset becomes `/odd:offset`.
   - Mind that the kit's offsets skip highlight wrapper elements.
   - Add round-trip tests on the existing fixtures.
   - Rationale: Bow's `docs/adr/0003-locator-cfi.md`. Bow uses CFI to sync progress and highlights with
     Grimmory's web reader.

## Housekeeping

9. **Tag releases on the fork** (e.g. `0.1.0`) once the configuration API settles, so Bow can pin a version
   instead of tracking `main`.
10. Point the README install URL at the fork, not upstream. Add `.macCatalyst(.v16)` to `platforms` in
    `Package.swift` so Catalyst support is explicit.
11. **Later, not now:** native macOS (ADR-0001, option B). Swap the `UIPageViewController` pager for an AppKit one
    and shim `UIColor`/`UIFont`/menus behind `#if os(macOS)`.
