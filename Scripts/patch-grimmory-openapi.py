#!/usr/bin/env python3
"""Turn Grimmory's vendored OpenAPI spec into input swift-openapi-generator can use.

Reads  Vendor/Grimmory/grimmory-openapi.json (never edited by hand)
Writes BowKit/Sources/GrimmoryAPI/openapi.json

Fixes the Spring/springdoc quirks listed in docs/grimmory-api.md:
  1. Responses declared as `*/*` with a JSON schema become `application/json`.
  2. Object-typed query parameters (Spring `@ModelAttribute`) are split into one query parameter per property,
     which is how Spring binds them.
  3. The `progressValid` property (leaked from an `@AssertTrue` getter) is dropped from `UpdateProgressRequest`.
  4. The CI machine's `servers` entry is removed; the client passes the user's server URL at runtime.
  5. Untyped `ResponseEntity<?>` responses Bow reads get their real shape (`SuccessResponse<T>`).

Which operations get generated is decided by `openapi-generator-config.yaml`, not here.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Vendor/Grimmory/grimmory-openapi.json"
OUTPUT = ROOT / "BowKit/Sources/GrimmoryAPI/openapi.json"

METHODS = {"get", "put", "post", "delete", "patch", "head", "options"}


def resolve(spec, schema):
    while "$ref" in schema:
        name = schema["$ref"].rsplit("/", 1)[-1]
        schema = spec["components"]["schemas"][name]
    return schema


def fix_wildcard_content(content):
    if "*/*" in content and "schema" in content["*/*"]:
        schema = content.pop("*/*")
        is_binary = schema["schema"].get("$ref", "").endswith("/StreamingResponseBody")
        content["application/octet-stream" if is_binary else "application/json"] = schema


def flatten_object_query_params(spec, operation):
    params = []
    for param in operation.get("parameters", []):
        schema = param.get("schema", {})
        target = resolve(spec, schema) if param.get("in") == "query" else {}
        if target.get("type") == "object" and "properties" in target:
            for name, prop in target["properties"].items():
                params.append({"name": name, "in": "query", "required": False, "schema": prop})
        else:
            params.append(param)
    if "parameters" in operation:
        operation["parameters"] = params


def main():
    spec = json.loads(SOURCE.read_text())
    spec.pop("servers", None)

    for path_item in spec["paths"].values():
        for method, operation in path_item.items():
            if method not in METHODS:
                continue
            flatten_object_query_params(spec, operation)
            for response in operation.get("responses", {}).values():
                fix_wildcard_content(response.get("content", {}))

    # SetupController returns `SuccessResponse<Boolean>` (`data` = setup already completed) as `ResponseEntity<?>`.
    spec["components"]["schemas"]["SetupStatusResponse"] = {
        "type": "object",
        "properties": {
            "status": {"type": "integer", "format": "int32"},
            "message": {"type": "string"},
            "data": {"type": "boolean"},
        },
    }
    status = spec["paths"]["/api/v1/setup/status"]["get"]["responses"]["200"]["content"]["application/json"]
    status["schema"] = {"$ref": "#/components/schemas/SetupStatusResponse"}

    progress = spec["components"]["schemas"].get("UpdateProgressRequest", {})
    progress.get("properties", {}).pop("progressValid", None)

    # Annotations and bookmarks are JPA entities with `LocalDateTime` stamps: no time zone and microseconds
    # ("2026-11-12T16:24:30.857306"), which a `date-time` decoder rejects. Keep them as strings.
    for name in ("Annotation", "BookMark"):
        for field in ("createdAt", "updatedAt"):
            spec["components"]["schemas"][name]["properties"][field].pop("format", None)

    # The healthcheck's timestamps are zone-less with nanoseconds ("2026-11-12T16:53:43.367803709").
    for name in ("HealthcheckResponse", "SuccessResponseHealthcheckResponse"):
        props = spec["components"]["schemas"].get(name, {}).get("properties", {})
        if "timestamp" in props:
            props["timestamp"].pop("format", None)

    # Assigning shelves answers with the full `Book` entities. Bow doesn't read them, and they're the heaviest,
    # least predictable schema in the spec, so don't let decoding them fail a call that already succeeded.
    assign = spec["paths"]["/api/v1/books/shelves"]["post"]["responses"]["200"]["content"]["application/json"]
    assign["schema"] = {}

    OUTPUT.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUTPUT.relative_to(ROOT)} (spec {spec['info']['version']})")


if __name__ == "__main__":
    sys.exit(main())
