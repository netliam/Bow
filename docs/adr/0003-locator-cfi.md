# ADR-0003: Reading locations as EPUB CFI

**Status:** Proposed
**Date:** 2026-11-11
**Deciders:** Liam

## Context
DCEpubReaderKit describes a location as `spineIndex` + an opaque `coords` string. `coords` is built by
`getCoordFromNode` in `EpubUtil.js` as the zero-padded child-index path from the root to the node, plus a character
offset. Grimmory's web reader (verify) stores EPUB positions as **EPUB CFI** strings plus a percentage. For progress
and highlights to move between Bow and the web app, both must understand the same location.

## Decision
Bow's stored `Locator` is `{ cfi: String?, percentage: Double, kitCoords: String?, spineIndex: Int }`.
The **CFI is canonical** for sync, and `kitCoords` is a local cache for fast reopen. Add `coordsToCFI` and
`cfiToCoords` to the fork's `EpubUtil.js`, and expose them on the reader view model. If a CFI can't be resolved
(e.g. the server's file is a different edition), fall back to percentage.

## Options Considered

### Option A: CFI in the kit (chosen)
| Dimension | Assessment |
|---|---|
| Complexity | Med. Mapping element indices to CFI even steps and text offsets to CFI `/odd:offset` steps. The kit's offset counting skips highlight wrappers, so the mapping must do the same. |
| Cost | JS + tests in the fork |
| Scalability | Standard format, works with any CFI-speaking server or client |
| Team familiarity | Medium |

**Pros:** True interop with the web reader for progress *and* highlights.
**Cons:** Edge cases (highlight spans, injected nodes, whitespace) need fixtures.

### Option B: Percentage only
**Pros:** Trivial.
**Cons:** Off by a page or more when switching devices. Highlights can't sync to the web at all.

### Option C: Store kit coords on the server as an opaque field
**Pros:** Exact between Bow devices.
**Cons:** The web app can't read them. Depends on the server having a field to put them in.

## Trade-off Analysis
Only A meets "do what the web can do" for annotations. The kit's coords are already a DOM path, so the conversion is
a well-scoped piece of JS rather than a redesign. B stays as a fallback, and C isn't needed.

## Consequences
- Easier: cross-client progress and highlights. Future KOReader/OPDS interop thinking is aligned.
- Harder: the fork must keep CFI conversion correct as the DOM handling evolves (e.g. stripped scripts, highlight merges).
- Revisit: whether Grimmory really uses CFI for its reader (verify before building). If it uses KOReader-style
  xpointers for some flows, add a second converter.

## Action Items
1. [ ] Confirm the format of Grimmory's progress and annotation payloads.
2. [ ] Implement `coordsToCFI` / `cfiToCoords` in `EpubUtil.js`, with round-trip tests on the fork's fixtures.
3. [ ] Expose conversion through a public API on the reader (or emit CFI alongside coords in `handleCoords`).
