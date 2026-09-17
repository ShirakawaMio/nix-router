#!/usr/bin/env python3
import ipaddress
import os
import re
import sys
import tempfile
import tomllib
import urllib.request
from pathlib import Path
from urllib.parse import urlparse

DOMAIN_RE = re.compile(r"^(?:[a-zA-Z0-9_*-]+\.)+[a-zA-Z0-9_-]+\.?$")


def die(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def read_toml(path: Path) -> dict:
    if not path.exists():
        die(f"missing rule config: {path}")
    with path.open("rb") as handle:
        return tomllib.load(handle)


def fetch_text(url: str, timeout: int = 30) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "my-router-rules/0.1"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def iter_source_lines(section: dict) -> list[str]:
    lines: list[str] = []
    for file_name in section.get("local_files", []):
        path = Path(file_name)
        if path.exists():
            lines.extend(path.read_text(encoding="utf-8", errors="replace").splitlines())
    for url in section.get("urls", []):
        lines.extend(fetch_text(url).splitlines())
    return lines


def iter_local_lines(section: dict) -> list[str]:
    return iter_source_lines({"local_files": section.get("local_files", [])})


def normalize_domain(raw: str) -> str | None:
    line = raw.strip()
    if line.startswith("-"):
        line = line[1:].strip().strip("'\"")
    if not line or line.startswith(("#", "!", "//")):
        return None

    if line.startswith("||"):
        line = line[2:].split("^", 1)[0].split("/", 1)[0]
    elif line.startswith("|http"):
        line = line.split("//", 1)[-1].split("/", 1)[0]
    elif line.startswith(("0.0.0.0 ", "127.0.0.1 ", ":: ")):
        parts = line.split()
        line = parts[1] if len(parts) > 1 else ""
    elif "," in line:
        maybe_type, maybe_value = [part.strip() for part in line.split(",", 1)]
        if maybe_type.upper() in {"DOMAIN", "DOMAIN-SUFFIX"}:
            line = maybe_value

    if line.startswith("+."):
        line = line[2:]
    elif line.startswith("."):
        line = line[1:]

    line = line.strip(" .")
    if not line or any(token in line for token in ["/", "*", "?", "^"]):
        return None
    if not DOMAIN_RE.match(line):
        return None
    return f"+.{line.lower()}"


def normalize_cidr(raw: str) -> str:
    value = raw.strip()
    ipaddress.ip_network(value, strict=False)
    return value


def validate_url(raw: str) -> None:
    value = raw.strip()
    parsed = urlparse(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        die(f"invalid URL: {value}")


def validate_domain(raw: str) -> None:
    value = raw.strip().lower().strip(".")
    if not value or not DOMAIN_RE.match(value):
        die(f"invalid domain: {raw}")


def validate_config(config: dict) -> None:
    publish = config.get("publish", {})
    public_base_url = publish.get("public_base_url", "")
    if public_base_url:
        validate_url(public_base_url)

    ads = config.get("ads", {})
    prebuilt_base_url = str(ads.get("prebuilt_base_url", "")).strip().rstrip("/")
    if prebuilt_base_url:
        validate_url(prebuilt_base_url)
        if ads.get("urls", []):
            die("ads.prebuilt_base_url and ads.urls are mutually exclusive")

    for url in ads.get("urls", []):
        validate_url(url)

    for value in config.get("office", {}).get("cidrs", []):
        normalize_cidr(value)

    rwth_section = config.get("rwth", {})
    for value in rwth_section.get("cidrs", []):
        normalize_cidr(value)
    for value in rwth_section.get("domains", []):
        validate_domain(value)


def write_provider(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    unique = sorted(dict.fromkeys(values))
    body = ["payload:"]
    body.extend(f"  - {yaml_quote(value)}" for value in unique)
    path.write_text("\n".join(body) + "\n", encoding="utf-8")


def write_shadowrocket_provider(path: Path, values: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    unique = sorted(dict.fromkeys(values))
    path.write_text("\n".join(unique) + "\n", encoding="utf-8")


def atomic_write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        handle.write(content)
        temp_path = Path(handle.name)
    os.chmod(temp_path, 0o644)
    os.replace(temp_path, path)


def write_prebuilt_ads(providers: Path, base_url: str, local_ads: list[str]) -> None:
    mihomo = fetch_text(f"{base_url}/ads.yaml")
    shadowrocket = fetch_text(f"{base_url}/ads-shadowrocket.list")
    if not mihomo.startswith("payload:\n"):
        die("prebuilt ads.yaml does not start with a payload mapping")
    if "\x00" in mihomo or "\x00" in shadowrocket:
        die("prebuilt ad rules contain NUL bytes")

    unique_local_ads = sorted(dict.fromkeys(local_ads))
    if unique_local_ads:
        mihomo = mihomo.rstrip("\n") + "\n"
        mihomo += "\n".join(f"  - {yaml_quote(value)}" for value in unique_local_ads) + "\n"
        shadowrocket = shadowrocket.rstrip("\n") + "\n"
        shadowrocket += "\n".join(
            f"DOMAIN-SUFFIX,{value.removeprefix('+.')}" for value in unique_local_ads
        ) + "\n"

    atomic_write_text(providers / "ads.yaml", mihomo)
    atomic_write_text(providers / "ads-shadowrocket.list", shadowrocket)


def main() -> None:
    args = sys.argv[1:]
    check_only = False
    if args and args[0] == "--check":
        check_only = True
        args = args[1:]

    config_path = Path(args[0]) if args else Path("/etc/my-router/rules/sources.toml")
    config = read_toml(config_path)
    validate_config(config)
    if check_only:
        print(f"validated {config_path}")
        return

    publish = config.get("publish", {})
    output_root = Path(os.environ.get("MY_ROUTER_WWW_DIR", publish.get("output_root", "/var/lib/my-router/www")))
    token = os.environ.get("PUBLISH_TOKEN", publish.get("token", "change-this-long-random-token"))
    root = output_root / token
    providers = root / "providers"

    ads_section = config.get("ads", {})
    prebuilt_ads_base_url = str(ads_section.get("prebuilt_base_url", "")).strip().rstrip("/")
    local_ads = [domain for line in iter_local_lines(ads_section) if (domain := normalize_domain(line))]
    ads = []
    if prebuilt_ads_base_url:
        write_prebuilt_ads(providers, prebuilt_ads_base_url, local_ads)
    else:
        ads = [domain for line in iter_source_lines(ads_section) if (domain := normalize_domain(line))]
    office_cidrs = [normalize_cidr(value) for value in config.get("office", {}).get("cidrs", [])]

    rwth_section = config.get("rwth", {})
    rwth_cidrs = [normalize_cidr(value) for value in rwth_section.get("cidrs", [])]
    rwth_domains = [value.strip().lower().strip(".") for value in rwth_section.get("domains", [])]
    rwth_payload = []
    rwth_shadowrocket = []
    for value in rwth_cidrs:
        network = ipaddress.ip_network(value, strict=False)
        rule_type = "IP-CIDR6" if network.version == 6 else "IP-CIDR"
        rwth_payload.append(f"{rule_type},{value}")
        rwth_shadowrocket.append(f"{rule_type},{value},no-resolve")
    rwth_payload.extend(f"DOMAIN-SUFFIX,{value}" for value in rwth_domains)
    rwth_shadowrocket.extend(f"DOMAIN-SUFFIX,{value}" for value in rwth_domains)

    office_shadowrocket = []
    for value in office_cidrs:
        network = ipaddress.ip_network(value, strict=False)
        rule_type = "IP-CIDR6" if network.version == 6 else "IP-CIDR"
        office_shadowrocket.append(f"{rule_type},{value},no-resolve")

    if not prebuilt_ads_base_url:
        write_provider(providers / "ads.yaml", ads)
        write_shadowrocket_provider(
            providers / "ads-shadowrocket.list",
            [f"DOMAIN-SUFFIX,{value.removeprefix('+.')}" for value in ads],
        )
    write_provider(providers / "office-cidr.yaml", office_cidrs)
    write_provider(providers / "rwth.yaml", rwth_payload)
    write_shadowrocket_provider(providers / "office-shadowrocket.list", office_shadowrocket)
    write_shadowrocket_provider(providers / "rwth-shadowrocket.list", rwth_shadowrocket)

    print(f"wrote rule files under {output_root}/<publish-token>")


if __name__ == "__main__":
    main()
