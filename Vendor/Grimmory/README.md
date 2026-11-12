# Grimmory OpenAPI spec (vendored)

`grimmory-openapi.json` is Grimmory's auto-generated OpenAPI document, copied unmodified. Bow generates its
Grimmory client from it (ADR-0004).

| | |
|---|---|
| Source | `grimmory-tools/grimmory`, GitHub Actions workflow `publish-nightly.yml` |
| Run / artifact | `42957057003` / `openapi-nightly-20261111-37ccdf4df` |
| Spec version | `nightly-20261111-37ccdf4df` (commit `37ccdf4`) |
| Downloaded | 2026-11-11 |
| SHA-256 | `d72f643f0e42f3bc238abcaaad1c91948389051a262d9734c6672e192a9d4865` |
| Format | OpenAPI 3.1.0, with 404 operations and 289 schemas |
| License | **AGPL-3.0** (Grimmory's license, declared in `info.license`) |

Bow is licensed AGPL as well, so vendoring this file and generating code from it is compatible.

## Updating

1. Get the newest nightly artifact:
   ```bash
   gh run list --repo grimmory-tools/grimmory --workflow publish-nightly.yml --status success --limit 1
   ```
   ```bash
   gh run download <run-id> --repo grimmory-tools/grimmory -n openapi-nightly-<date>-<sha> -D /tmp/grimmory-openapi
   ```
   Or start a Grimmory server with `API_DOCS_ENABLED=true` and save `GET /api/openapi.json`.
2. Replace the file here, and update the table above.
3. Run `Scripts/generate-grimmory-api.sh`, which patches the spec and regenerates
   `BowKit/Sources/GrimmoryAPI/Generated`. Then review the diff. Grimmory describes its API as unstable.

Don't edit this file by hand. The fixes the generator needs (`*/*` → `application/json`, dropping
`progressValid`, and others) belong in a patch step that reads this file. See `docs/grimmory-api.md`.
