# ADR-0001: Mac via Catalyst for v1

**Status:** Proposed
**Date:** 2026-11-11
**Deciders:** Liam

## Context
Bow must run on iPhone, iPad and Mac. DCEpubReaderKit only declares `platforms: [.iOS(.v16)]` and imports UIKit in
about 16 files. The hard parts are `DCPagedReaderController`/`DCPageWebViewController` (`UIPageViewController`), the
highlight edit menu, the image viewer, and `UIColor`/`UIFont` in the preferences and fonts code. The rendering core
(`WKWebView` + `EpubUtil.js`) and the parser/core targets are already cross-platform. The Bow project is currently
set up as a native multiplatform app (`macosx` in `SUPPORTED_PLATFORMS`).

## Decision
Ship v1 on Mac as **Mac Catalyst** ("Optimize for Mac"). Keep app code in plain SwiftUI with no UIKit outside a thin
platform layer, so a later move to native macOS only changes the reader.

## Options Considered

### Option A: Mac Catalyst
| Dimension | Assessment |
|---|---|
| Complexity | Low. The kit works as it is. |
| Cost | Mac feel is decent but not fully native (menus, windows need some tuning) |
| Scalability | Fine |
| Team familiarity | High, same code as iPad |

**Pros:** Zero kit changes. One binary target. Reader behavior is identical to iPad.
**Cons:** A slightly less native Mac. Some AppKit-only features (e.g. `Settings` scene nuances) need workarounds.

### Option B: Native macOS + port the kit
| Dimension | Assessment |
|---|---|
| Complexity | High. The pager needs a Mac version (CSS columns in one `WKWebView`, or `NSPageController`). Menus, colors and fonts need `#if os` shims. |
| Cost | Weeks of work in the fork before Bow can read a book on Mac |
| Scalability | Best long-term Mac experience |
| Team familiarity | Medium |

**Pros:** A truly native Mac app. Also benefits other users of the kit.
**Cons:** Blocks the Mac reader on a large port. Two code paths to maintain in the reader.

### Option C: Native macOS app, reader on iOS/iPad only at first
**Pros:** Native library UI.
**Cons:** An e-reader that can't read on Mac isn't shippable there.

## Trade-off Analysis
The reader is the product. Option B puts the most important feature behind the biggest chunk of work. Catalyst gets
a working Mac reader immediately. Keeping the app layer platform-neutral makes B a contained follow-up rather than
a rewrite.

## Consequences
- Easier: one UI codebase, kit unchanged, fast to ship.
- Harder: Mac polish (menu commands, multiple reader windows, keyboard paging) needs Catalyst-specific attention.
- Revisit: after v1, if Mac usage justifies it, port the kit's pager to AppKit and switch the target to native macOS.

## Action Items
1. [ ] Change the target's destinations to iPhone, iPad and Mac (Catalyst). Remove native `macosx` and `xros` unless wanted.
2. [ ] Enable the outgoing-network entitlement for the Mac build.
3. [ ] Add keyboard paging (←/→, space) and a menu bar "Go to" command in the reader.
