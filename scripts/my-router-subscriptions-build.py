#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlparse


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def read_json(path: Path) -> dict:
    if not path.exists():
        die(f"missing subscription config: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"invalid JSON in {path}: {exc}")


def request(url: str, method: str = "GET", payload: object | None = None, timeout: int = 120) -> bytes:
    data = None
    headers = {"User-Agent": "my-router-subscriptions/0.1"}
    if payload is not None:
        data = json.dumps(payload, ensure_ascii=True).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        die(f"Sub-Store request failed ({exc.code}): {detail}")
    except urllib.error.URLError as exc:
        die(f"Sub-Store request failed: {exc.reason}")


def wait_for_backend(base_url: str, timeout: int = 30) -> None:
    deadline = time.monotonic() + timeout
    health_url = f"{base_url}/api/utils/env"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(health_url, timeout=2) as response:
                if response.status == 200:
                    return
        except (urllib.error.URLError, TimeoutError):
            time.sleep(0.5)
    die(f"Sub-Store backend did not become ready at {base_url}")


def load_subscriptions(path_value: str | None) -> list[dict]:
    if not path_value:
        return []
    source_path = Path(path_value)
    source_config = read_json(source_path)
    raw_subscriptions = source_config.get("subscriptions", [])
    if not isinstance(raw_subscriptions, list):
        die(f"subscriptions must be a list in {source_path}")

    subscriptions: list[dict] = []
    names: set[str] = set()
    for item in raw_subscriptions:
        if not isinstance(item, dict):
            die(f"each subscription in {source_path} must be an object")
        name = str(item.get("name", "")).strip()
        if not name or "/" in name:
            die(f"invalid subscription name: {name!r}")
        if name in names:
            die(f"duplicate subscription name: {name}")
        names.add(name)

        url = str(item.get("url", "")).strip()
        content = item.get("content")
        if bool(url) == bool(content):
            die(f"subscription {name} must define exactly one of url or content")

        subscription = {"name": name, "process": []}
        if url:
            parsed = urlparse(url)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                die(f"subscription {name} has an invalid URL")
            subscription.update({"source": "remote", "url": url})
            user_agent = str(item.get("user_agent", "")).strip()
            if user_agent:
                subscription["ua"] = user_agent
        else:
            if not isinstance(content, str) or not content.strip():
                die(f"subscription {name} has empty local content")
            subscription.update({"source": "local", "content": content})
        subscriptions.append(subscription)
    return subscriptions


def read_secret(path_value: object, label: str) -> str:
    path = Path(str(path_value or ""))
    try:
        value = path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        die(f"cannot read {label} from {path}: {exc}")
    if not value:
        die(f"{label} is empty: {path}")
    return value


def load_access_subscription(config: dict) -> dict | None:
    access = config.get("access_node")
    if not isinstance(access, dict) or not access.get("enabled", False):
        return None

    required = ["name", "server", "port", "ip", "client_private_key_file", "server_private_key_file"]
    missing = [key for key in required if not access.get(key)]
    if missing:
        die(f"access_node is missing: {', '.join(missing)}")

    client_private_key = read_secret(access["client_private_key_file"], "access client private key")
    server_private_key = read_secret(access["server_private_key_file"], "access server private key")
    try:
        result = subprocess.run(
            ["wg", "pubkey"],
            input=server_private_key + "\n",
            text=True,
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        die(f"cannot derive access server public key: {exc}")
    server_public_key = result.stdout.strip()
    if not server_public_key:
        die("derived access server public key is empty")

    content = {
        "proxies": [
            {
                "name": str(access["name"]),
                "type": "wireguard",
                "server": str(access["server"]),
                "port": int(access["port"]),
                "ip": str(access["ip"]),
                "private-key": client_private_key,
                "public-key": server_public_key,
                "udp": True,
            }
        ]
    }
    return {
        "name": "__my-router-access",
        "source": "local",
        "content": json.dumps(content, ensure_ascii=True),
        "process": [],
    }


def atomic_write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        handle.write(content)
        temp_path = Path(handle.name)
    os.chmod(temp_path, 0o644)
    os.replace(temp_path, path)


def read_rule_lines(path: Path) -> list[str]:
    try:
        return [
            line.strip()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    except OSError as exc:
        die(f"cannot read generated rules from {path}: {exc}")


def apply_policy(rule: str, policy: str) -> str:
    parts = [part.strip() for part in rule.split(",")]
    if parts[-1].lower() == "no-resolve":
        parts.insert(-1, policy)
    else:
        parts.append(policy)
    return ",".join(parts)


def load_inline_rules(root: Path) -> list[str]:
    providers = root / "providers"
    rules: list[str] = []
    for file_name, policy in [
        ("ads-shadowrocket.list", "REJECT"),
        ("office-shadowrocket.list", "OFFICE"),
        ("rwth-shadowrocket.list", "RWTH"),
    ]:
        rules.extend(apply_policy(rule, policy) for rule in read_rule_lines(providers / file_name))
    return rules


def render_mihomo(nodes: list[dict], rules: list[str]) -> str:
    proxy_lines = "\n".join(
        f"  - {json.dumps(node, ensure_ascii=True, separators=(',', ':'))}" for node in nodes
    )
    proxies = f"proxies:\n{proxy_lines}" if proxy_lines else "proxies: []"
    node_names = list(dict.fromkeys(str(node.get("name", "")).strip() for node in nodes))
    node_names = [name for name in node_names if name]
    proxy_members = node_names + ["DIRECT"]

    def group_members(names: list[str]) -> str:
        return "\n".join(f"      - {yaml_quote(name)}" for name in names)

    rule_lines = "\n".join(f"  - {rule}" for rule in rules)
    return f"""mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

{proxies}

proxy-groups:
  - name: PROXY
    type: select
    proxies:
{group_members(proxy_members)}
  - name: OFFICE
    type: select
    proxies:
      - PROXY
      - DIRECT
  - name: RWTH
    type: select
    proxies:
      - PROXY
      - DIRECT
  - name: FINAL
    type: select
    proxies:
      - DIRECT
      - PROXY

rules:
{rule_lines}
  - MATCH,FINAL
"""


def render_shadowrocket(base_url: str, rules: list[str]) -> str:
    rule_lines = "\n".join(rules)
    return f"""# Generated by my-router. Import nodes from {base_url}/nodes/shadowrocket.txt
[General]
bypass-system = true
skip-proxy = 127.0.0.1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,localhost,*.local
dns-server = system,1.1.1.1
update-url = {base_url}/shadowrocket.conf

[Proxy Group]
PROXY = select,policy-regex-filter=.*,DIRECT,select=0
OFFICE = select,PROXY,DIRECT
RWTH = select,PROXY,DIRECT
FINAL = select,DIRECT,PROXY

[Rule]
{rule_lines}
FINAL,FINAL
"""


def main() -> None:
    config_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/etc/my-router/subscriptions/config.json")
    config = read_json(config_path)
    backend_url = str(config.get("backend_url", "http://127.0.0.1:3000")).rstrip("/")
    collection_name = str(config.get("collection_name", "my-router")).strip()
    sources_file = config.get("sources_file")
    allow_insecure = bool(config.get("allow_insecure_publication", False))

    output_root = Path(os.environ.get("MY_ROUTER_WWW_DIR", "/var/lib/my-router/www"))
    token = os.environ.get("PUBLISH_TOKEN", "").strip()
    base_url = os.environ.get("PUBLISH_BASE_URL", "").strip().rstrip("/")
    if not token or not base_url:
        die("PUBLISH_TOKEN and PUBLISH_BASE_URL must be set")

    subscriptions = load_subscriptions(sources_file)
    access_subscription = load_access_subscription(config)
    if access_subscription is not None:
        if any(item["name"] == access_subscription["name"] for item in subscriptions):
            die(f"reserved subscription name is in use: {access_subscription['name']}")
        subscriptions.insert(0, access_subscription)
    if subscriptions and urlparse(base_url).scheme != "https" and not allow_insecure:
        die("refusing to publish node credentials over non-HTTPS; configure HTTPS or allow_insecure_publication")

    wait_for_backend(backend_url)
    request(f"{backend_url}/api/subs", method="PUT", payload=subscriptions)
    collection = {"name": collection_name, "subscriptions": [item["name"] for item in subscriptions], "process": []}
    request(f"{backend_url}/api/collections", method="PUT", payload=[collection])

    if subscriptions:
        encoded_name = quote(collection_name, safe="")
        mihomo_nodes = request(f"{backend_url}/download/collection/{encoded_name}/Mihomo?prettyYaml=true")
        shadowrocket_nodes = request(f"{backend_url}/download/collection/{encoded_name}/V2Ray")
        raw_nodes = request(f"{backend_url}/download/collection/{encoded_name}/Mihomo?produceType=internal")
        try:
            parsed_nodes = json.loads(raw_nodes)
        except json.JSONDecodeError as exc:
            die(f"Sub-Store returned invalid internal node JSON: {exc}")
        if not isinstance(parsed_nodes, list):
            die("Sub-Store internal node output is not a list")
        nodes = [
            {key: value for key, value in node.items() if not key.startswith("_")}
            for node in parsed_nodes
            if isinstance(node, dict)
        ]
    else:
        mihomo_nodes = b"proxies: []\n"
        shadowrocket_nodes = b""
        nodes = []

    root = output_root / token
    rules = load_inline_rules(root)
    atomic_write(root / "nodes" / "mihomo.yaml", mihomo_nodes)
    atomic_write(root / "nodes" / "shadowrocket.yaml", shadowrocket_nodes)
    atomic_write(root / "nodes" / "shadowrocket.txt", shadowrocket_nodes)
    mihomo_config = render_mihomo(nodes, rules).encode("utf-8")
    atomic_write(root / "mihomo.yaml", mihomo_config)
    atomic_write(root / "stash.yaml", mihomo_config)
    atomic_write(root / "shadowrocket.conf", render_shadowrocket(base_url, rules).encode("utf-8"))
    print(
        f"published {len(nodes)} node(s) from {len(subscriptions)} source(s) and "
        f"{len(rules)} inline rule(s) under {output_root}/<publish-token>"
    )


if __name__ == "__main__":
    main()
