#!/usr/bin/env python3
"""Regenerate Sources/TheGit/Resources/providers.json from dim-agent.

dim-agent's default-catalog.json is the merged, normalised provider catalog
its TypeScript AI SDK layer ships (~3.2MB, 98 providers, 3000 models). Almost
all of that is pricing, reasoning knobs and the raw upstream record — none of
which TheGit needs to send a single chat completion. This projects the four
things we do need (endpoint, auth shape, wire adapter, model ids) into a
~270KB file that gets bundled with the app.

The generated JSON is committed; this script only runs when someone wants to
refresh it. dim-agent missing is an error, not a reason to write a stub.

    scripts/sync-providers.py [--from ~/Git/dim-agent] [--check]
"""

import argparse
import json
import os
import sys

CATALOG = "packages/agent/src/provider/catalog/default-catalog.json"

# Wire protocols TheGit speaks. Everything else collapses onto the OpenAI
# chat/completions shape, which every one of those variants also accepts.
ADAPTERS = {"openai", "anthropic", "gemini"}

# Model kinds we can use. dim-agent's catalog also carries image, video,
# speech and music models; a commit message needs none of them.
CHAT_TYPES = {None, "chat", "code"}

# dim-agent's own "bring your own endpoint" placeholder — TheGit ships its
# own Custom entry, built in Swift.
SKIP = {"custom-provider"}

# Providers the catalog only lists speech/image models for, but whose
# endpoint is an ordinary OpenAI-compatible chat API. Keeping them with an
# empty list (models fetched at runtime) beats dropping them outright.
CHAT_ANYWAY = {"groq", "mistral-ai", "together-ai"}

# google.json carries no endpoint because dim-agent's Gemini driver knows it.
BASE_URL_FALLBACK = {"google": "https://generativelanguage.googleapis.com/v1beta"}


# Effort levels, cheapest first. Models that can't switch thinking off get
# the lowest one they offer.
EFFORTS = ["none", "minimal", "low", "medium", "high"]


def thinking_off(model):
    """How to stop this model from thinking, or None if it doesn't by default.

    A commit message is not a reasoning problem: thinking tokens on a model
    like deepseek-v4-flash (reasoning on unless told otherwise) are pure
    latency and cost here. dim-agent already curates the per-model switch,
    which is the only reason this is knowable at all.
    """
    reasoning = (model.get("metadata") or {}).get("reasoning") or {}
    # Off already, or nothing to turn off.
    if not reasoning.get("supported") or not reasoning.get("defaultEnabled"):
        return None

    node = {}
    if off := reasoning.get("off"):
        node["off"] = off["kind"]  # thinking_type | enable_thinking | thinking_budget
    for effort in EFFORTS:
        if effort in (reasoning.get("effortOptions") or []):
            node["effort"] = effort
            break
    return node or None


def project(catalog):
    providers = []
    for entry in catalog["providers"]:
        auth = entry.get("auth") or {}
        # No OAuth flows here: two providers use them and both need a browser
        # round-trip we have no UI for.
        if auth.get("type") != "api_key" or entry["providerId"] in SKIP:
            continue

        meta = entry.get("metadata") or {}
        adapter = meta.get("adapter") or entry.get("driverKind") or "openai"
        if adapter not in ADAPTERS:
            adapter = "openai"

        models = []
        for model in entry.get("models") or []:
            if model.get("status") == "deprecated":
                continue
            raw = (model.get("metadata") or {}).get("raw") or {}
            if raw.get("type") not in CHAT_TYPES:
                continue
            caps = model.get("capabilities") or {}
            slim = {"id": model["modelId"], "name": model["displayName"]}
            if caps.get("contextWindow"):
                slim["ctx"] = caps["contextWindow"]
            if caps.get("maxOutputTokens"):
                slim["out"] = caps["maxOutputTokens"]
            if reasoning := thinking_off(model):
                slim["noThink"] = reasoning
            models.append(slim)

        base = entry.get("defaultBaseUrl") or BASE_URL_FALLBACK.get(entry["providerId"])
        if not base:
            continue

        # No chat models and no runtime model list means it is an image or
        # speech shop — nothing here can write a commit message.
        byo = bool(meta.get("customModels")) or entry["providerId"] in CHAT_ANYWAY
        if not models and not byo:
            continue

        provider = {
            "id": entry["providerId"],
            "name": entry["displayName"],
            "adapter": adapter,
            "auth": {
                "header": auth.get("headerName") or "Authorization",
                "prefix": auth.get("prefix") or "",
            },
            "baseUrl": base.rstrip("/"),
            "models": models,
        }
        if meta.get("defaultModelId"):
            provider["defaultModelId"] = meta["defaultModelId"]
        # Ask the endpoint for its models when the catalog can't know them.
        if byo:
            provider["customModels"] = True
        providers.append(provider)

    providers.sort(key=lambda p: p["name"].lower())
    return {"updatedAt": catalog.get("updatedAt", ""), "providers": providers}


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--from",
        dest="source",
        default=os.path.expanduser("~/Git/dim-agent"),
        help="path to a dim-agent checkout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail instead of writing when the output would change",
    )
    args = parser.parse_args()

    src = os.path.join(args.source, CATALOG)
    if not os.path.isfile(src):
        sys.exit(f"no catalog at {src} — pass --from <dim-agent checkout>")

    with open(src, encoding="utf-8") as handle:
        slim = project(json.load(handle))

    # Compact separators: this file is parsed, never read.
    text = json.dumps(slim, ensure_ascii=False, separators=(",", ":")) + "\n"
    out = os.path.join(root, "Sources/TheGit/Resources/providers.json")

    if args.check:
        current = open(out, encoding="utf-8").read() if os.path.isfile(out) else ""
        if current != text:
            sys.exit(f"{out} is stale — run scripts/sync-providers.py")
        print("providers.json is up to date")
        return

    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as handle:
        handle.write(text)

    models = sum(len(p["models"]) for p in slim["providers"])
    print(
        f"wrote {out}: {len(slim['providers'])} providers, "
        f"{models} models, {len(text.encode()) // 1024}KB"
    )


if __name__ == "__main__":
    main()
