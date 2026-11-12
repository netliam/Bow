# ADR-0004: Grimmory client from the OpenAPI spec

**Status:** Accepted
**Date:** 2026-11-11
**Deciders:** Liam

## Context
Bow aims for near-parity with the Grimmory web app, which means covering a large REST surface (books, libraries,
shelves, magic shelves, metadata, progress, annotations, uploads, auth). Grimmory is a Spring Boot backend.
It publishes no API docs, but every controller is annotated for springdoc. A running server with
`API_DOCS_ENABLED=true` serves the full spec at `/api/openapi.json`, and the nightly CI exports
`grimmory-openapi.json` (see `grimmory-api.md`). The API will change as Grimmory evolves.

## Decision
Generate `GrimmoryAPI` with **swift-openapi-generator** from a vendored copy of Grimmory's OpenAPI spec. Wrap it in a
small hand-written `GrimmoryClient` facade that handles auth/refresh, pagination and DTO → domain mapping. Other
modules only see the facade. If no usable spec exists, hand-write the facade against the same interface.

## Options Considered

### Option A: Generated client + facade
| Dimension | Assessment |
|---|---|
| Complexity | Low–Med |
| Cost | Build plugin dependency (Apple-maintained) |
| Scalability | Updating to a new server version means updating the spec and fixing compile errors |
| Team familiarity | Medium |

**Pros:** Full coverage quickly. Type-safe. API drift shows up at compile time.
**Cons:** Spring-generated specs can be loose (missing `required`, generic `object`s) and may need a patch step.

### Option B: Hand-written client
| Dimension | Assessment |
|---|---|
| Complexity | Med–High at parity scale |
| Cost | Ongoing manual upkeep |
| Scalability | Drifts silently |
| Team familiarity | High |

**Pros:** Precise models, no generator quirks.
**Cons:** A lot of boilerplate for ~parity coverage. Bugs only show up at runtime.

### Option C: OPDS + KOReader sync only
**Pros:** Standard protocols, works with other servers too.
**Cons:** Read-only catalog, no shelves/metadata/annotations. Fails the parity goal. A good *extra* later for
non-Grimmory servers.

## Trade-off Analysis
Parity means breadth, and breadth favors generation. The facade keeps generator quirks out of the rest of the app
and lets individual calls be hand-written when the spec is wrong.

## Consequences
- Easier: adding web features means mostly calling an existing generated operation.
- Harder: build-plugin setup, and a spec-patching step if Grimmory's spec is incomplete.
- Revisit: adding an OPDS account type later so Bow can also connect to Calibre-Web/Kavita-style servers.

## Action Items
1. [x] Vendor the spec: `Vendor/Grimmory/grimmory-openapi.json` (nightly `37ccdf4`, AGPL-3.0, compatible with
   Bow's AGPL license). Provenance and update steps are in `Vendor/Grimmory/README.md`.
2. [ ] Write the patch step (see the quirks table in `grimmory-api.md`) that writes the generator input to
   `BowKit/Sources/GrimmoryAPI/openapi.json`, filtered to the operations Bow uses.
3. [ ] Set up the generator plugin. Write `GrimmoryClient` with login, a **single-flight** refresh (refresh
   tokens rotate), Keychain-stored tokens, and a 401 → refresh → retry flow.
4. [ ] Write contract tests against recorded responses.
