#!/usr/bin/env python3
"""Pubblica la build sul repository pubblico delle IPA (solo IPA, icona,
CHANGELOG e sorgente apps.json in formato AltStore/LiveContainer).

Uso in CI: RELEASES_TOKEN=... python3 tools/publish_public.py VERSION BUILD IPA ICON NOTES
Il codice dell'app resta nel repository privato.
"""
import base64
import datetime as dt
import json
import os
import sys
import urllib.error
import urllib.request

REPO = "cipherdesk007-max/quantswarm-releases"
BUNDLE = "com.quantswarm.alphazero"
API = "https://api.github.com"
TOKEN = os.environ["RELEASES_TOKEN"]


def call(method, url, data=None, content_type="application/json", raw=False):
    body = None
    if data is not None:
        body = data if isinstance(data, bytes) else json.dumps(data).encode()
    req = urllib.request.Request(url, data=body, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": content_type,
        "User-Agent": "quantswarm-ci",
    })
    try:
        with urllib.request.urlopen(req) as resp:
            payload = resp.read()
            return payload if raw else (json.loads(payload) if payload else {})
    except urllib.error.HTTPError as err:
        # 404 = risorsa assente (release che non esiste ancora, file nuovo);
        # 409 = "Git Repository is empty" su un repository appena creato.
        # In entrambi i casi si prosegue: il chiamante gestisce il caso "manca".
        if err.code in (404, 409):
            return None
        raise SystemExit(f"{method} {url} -> {err.code}: {err.read()[:400]!r}")


def ensure_initialized():
    """Un repository senza commit non può ricevere né release (422
    "Repository is empty") né file via contents API (409): serve un primo
    commit. Se manca, lo crea via git data API (blob -> tree -> commit ->
    branch di default), poi tutto il resto funziona normalmente."""
    repo = call("GET", f"{API}/repos/{REPO}") or {}
    branch = repo.get("default_branch") or "main"
    if call("GET", f"{API}/repos/{REPO}/git/ref/heads/{branch}"):
        return  # già inizializzato
    blob = call("POST", f"{API}/repos/{REPO}/git/blobs", {
        "content": "# FMLAB QuantSwarm Alpha Zero\n\n"
                   "Repository pubblico delle IPA per gli aggiornamenti via "
                   "LiveContainer/SideStore (sorgente apps.json, icona e IPA).\n",
        "encoding": "utf-8",
    })
    tree = call("POST", f"{API}/repos/{REPO}/git/trees", {
        "tree": [{"path": "README.md", "mode": "100644", "type": "blob",
                  "sha": blob["sha"]}],
    })
    commit = call("POST", f"{API}/repos/{REPO}/git/commits", {
        "message": "init: primo commit (release e apps.json richiedono una storia)",
        "tree": tree["sha"],
        "parents": [],
    })
    call("POST", f"{API}/repos/{REPO}/git/refs", {
        "ref": f"refs/heads/{branch}", "sha": commit["sha"]})
    print(f"Repository {REPO} inizializzato (branch {branch}, commit {commit['sha'][:7]})")


def put_file(path, content_bytes, message):
    current = call("GET", f"{API}/repos/{REPO}/contents/{path}")
    data = {"message": message, "content": base64.b64encode(content_bytes).decode()}
    if current and "sha" in current:
        data["sha"] = current["sha"]
    call("PUT", f"{API}/repos/{REPO}/contents/{path}", data)


def main():
    version, build, ipa, icon, notes_path = sys.argv[1:6]
    tag = f"v{version}"
    notes = open(notes_path, encoding="utf-8").read().strip()
    ipa_bytes = open(ipa, "rb").read()
    ensure_initialized()

    release = call("GET", f"{API}/repos/{REPO}/releases/tags/{tag}")
    if release is None:
        release = call("POST", f"{API}/repos/{REPO}/releases", {
            "tag_name": tag, "name": f"FMLAB QuantSwarm Alpha Zero {version}",
            "body": notes, "make_latest": "true",
        })
    else:
        call("PATCH", f"{API}/repos/{REPO}/releases/{release['id']}", {"body": notes})
    for asset in release.get("assets", []):
        if asset["name"] == "QuantSwarm-Alpha-Zero.ipa":
            call("DELETE", f"{API}/repos/{REPO}/releases/assets/{asset['id']}")
    upload = release["upload_url"].split("{")[0] + "?name=QuantSwarm-Alpha-Zero.ipa"
    call("POST", upload, ipa_bytes, content_type="application/octet-stream")

    download = f"https://github.com/{REPO}/releases/download/{tag}/QuantSwarm-Alpha-Zero.ipa"
    icon_url = f"https://raw.githubusercontent.com/{REPO}/main/icon.png"
    existing = call("GET", f"{API}/repos/{REPO}/contents/apps.json")
    source = None
    if existing and existing.get("content"):
        try:
            source = json.loads(base64.b64decode(existing["content"]))
        except ValueError:
            source = None
    if not source:
        source = {"name": "FMLAB", "identifier": "fmlab.quantswarm.source",
                  "sourceURL": f"https://raw.githubusercontent.com/{REPO}/main/apps.json", "apps": []}
    apps = [a for a in source.get("apps", []) if a.get("bundleIdentifier") == BUNDLE]
    app = apps[0] if apps else {
        "name": "QuantSwarm Alpha Zero", "bundleIdentifier": BUNDLE, "developerName": "FMLAB",
        "subtitle": "Trading con agenti AI su Alpaca", "iconURL": icon_url,
        "localizedDescription": "Agenti Kimi scelgono, le regole proteggono, Alpaca esegue.", "versions": [],
    }
    app["iconURL"] = icon_url
    versions = [v for v in app.get("versions", []) if v.get("version") != version]
    versions.insert(0, {
        "version": version, "buildVersion": str(build),
        "date": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": notes[:4000], "downloadURL": download,
        "size": len(ipa_bytes), "minOSVersion": "17.0",
    })
    app["versions"] = versions[:20]
    source["apps"] = [app] + [a for a in source.get("apps", []) if a.get("bundleIdentifier") != BUNDLE]

    put_file("apps.json", json.dumps(source, indent=2, ensure_ascii=False).encode(), f"sorgente: {version} build {build}")
    put_file("icon.png", open(icon, "rb").read(), "icona")
    print(f"Pubblicato {tag} build {build} su {REPO}")


if __name__ == "__main__":
    main()
