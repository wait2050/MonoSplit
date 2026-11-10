#!/usr/bin/env python3
"""Collect locked macOS Cargo dependency notices for source and binary releases."""
import argparse
import json
import pathlib
import re
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=pathlib.Path)
    args = parser.parse_args()
    metadata = json.loads(args.metadata.read_text()) if args.metadata else json.loads(subprocess.check_output([
        "cargo", "metadata", "--manifest-path", str(ROOT / "gpui/Cargo.toml"),
        "--locked", "--format-version", "1", "--filter-platform", "aarch64-apple-darwin",
    ]))
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    packages = {package["id"]: package for package in metadata["packages"]}
    seen = set()
    pending = [metadata["resolve"]["root"]]
    while pending:
        identity = pending.pop()
        if identity in seen:
            continue
        seen.add(identity)
        pending.extend(dependency["pkg"] for dependency in nodes[identity]["deps"])
    selected = sorted((packages[identity] for identity in seen if packages[identity].get("source")),
                      key=lambda package: (package["name"], package["version"]))
    destination = ROOT / "third-party-licenses"
    destination.mkdir(exist_ok=True)
    lines = [
        "# Third-party notices / 第三方声明", "",
        "MonoSplit's original code is licensed under 0BSD. Dependencies and bundled assets retain their own licenses.",
        "MonoSplit 自有代码采用 0BSD；第三方代码与资源保留其原有许可证。", "",
        "This inventory follows Cargo.lock and the resolved Apple Silicon macOS dependency graph, including build dependencies.",
        "It is a notice inventory, not a claim that every listed package is linked into the final executable.",
        "License expressions are preserved as declared by each package; OR alternatives remain alternatives.", "",
        "GPUI 0.2.2, gpui-component 0.5.1 and gpui-component-assets 0.5.1 are Apache-2.0.",
        "Icons bundled by gpui-component-assets originate from Lucide; see [Lucide's license](third-party-licenses/lucide/LICENSE).", "",
        "For MPL-2.0 packages, unmodified source archives are included beside their notices. No third-party source was modified.",
        "FineTune Sync is a separate GPL-3.0 application: https://github.com/wait2050/FineTune-Sync/blob/main/LICENSE.", "",
        "Regenerate with `python3 scripts/generate-third-party-notices.py` after changing Cargo.lock.", "",
        "| Package | Declared license | Notices and source |", "| --- | --- | --- |",
    ]
    for package in selected:
        name, version = package["name"], package["version"]
        folder = pathlib.Path(package["manifest_path"]).parent
        target = destination / f"{name}-{version}"
        collected = []
        license_file = package.get("license_file")
        candidates = list(folder.rglob("*"))
        for source in candidates:
            if not source.is_file() or not (re.match(r"^(?:licen[cs]e|copying|notice|copyright)(?:[.\-_]|$)", source.name, re.I)
                                            or (license_file and source == folder / license_file)):
                continue
            if source.stat().st_size > 1_000_000:
                continue
            relative = source.relative_to(folder)
            output = target / relative
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, output)
            collected.append(relative.as_posix())
        expression = package.get("license") or "See package source"
        target.mkdir(parents=True, exist_ok=True)
        attribution = [f"# {name} {version}", "", f"Declared license: {expression}", "",
                       "Upstream authors: " + (", ".join(package.get("authors", [])) or "Not specified in package metadata"),
                       "Repository: " + str(package.get("repository") or "See crates.io"), "",
                       f"Original source archive: https://static.crates.io/crates/{name}/{name}-{version}.crate", "",
                       "Package-provided copyright and license notices are preserved alongside this attribution.",
                       "Standard license reference texts are in ../terms/. The package's declared OR alternatives remain alternatives.", ""]
        (target / "ATTRIBUTION.md").write_text("\n".join(attribution))
        collected.append("ATTRIBUTION.md")
        if "MPL-2.0" in expression:
            registry = folder.parent.name
            archive = pathlib.Path.home() / ".cargo/registry/cache" / registry / f"{name}-{version}.crate"
            if not archive.exists():
                raise SystemExit(f"Missing MPL source archive: {archive}")
            target.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(archive, target / "source.crate")
            collected.append("source.crate")
        crate_url = f"https://crates.io/crates/{name}/{version}"
        source_url = f"https://static.crates.io/crates/{name}/{name}-{version}.crate"
        notice = f"[notices](third-party-licenses/{name}-{version}/)" if collected else "license in upstream source"
        lines.append(f"| [{name} {version}]({crate_url}) | {expression} | {notice}; [source]({source_url}) |")
    (ROOT / "THIRD_PARTY_NOTICES.md").write_text("\n".join(lines) + "\n")
    print(f"Collected notices for {len(selected)} locked macOS dependencies")


if __name__ == "__main__":
    main()
