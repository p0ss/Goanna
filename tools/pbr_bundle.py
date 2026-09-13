#!/usr/bin/env python3
"""Build, verify and install versioned Goanna PBR asset bundles."""

import argparse
import hashlib
import json
import shutil
import stat
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

SCHEMA = "org.goanna.asset-bundle/v1"
CATALOGUE_SCHEMA = "org.goanna.asset-catalogue/v1"
ZIP_TIME = (1980, 1, 1, 0, 0, 0)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical_json(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode()


def accepted_stems(quality_path):
    if not quality_path:
        return None
    report = json.loads(Path(quality_path).read_text())
    return {row["stem"] for row in report["textures"] if not row["failures"]}


def payload(texture_dir, accepted):
    result = {}
    for path in sorted(Path(texture_dir).glob("*.png")):
        name = path.name
        if not (name.endswith("_n.png") or name.endswith("_s.png")):
            continue
        stem = name[:-6]
        if accepted is not None and stem not in accepted:
            continue
        result[f"textures/{name}"] = path.read_bytes()
    return result


def validate_pairs(files):
    names = {PurePosixPath(name).name for name in files if name.startswith("textures/")}
    normals = {name[:-6] for name in names if name.endswith("_n.png")}
    specs = {name[:-6] for name in names if name.endswith("_s.png")}
    if not normals or normals != specs:
        raise ValueError("bundle must contain matching, non-empty _n/_s texture pairs")
    return sorted(normals)


def zip_bytes(files):
    with tempfile.NamedTemporaryFile(suffix=".zip") as tmp:
        with zipfile.ZipFile(tmp.name, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            for name in sorted(files):
                info = zipfile.ZipInfo(name, ZIP_TIME)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                info.create_system = 3
                archive.writestr(info, files[name], compresslevel=9)
        return Path(tmp.name).read_bytes()


def build(args):
    accepted = accepted_stems(args.quality)
    files = payload(args.textures, accepted)
    stems = validate_pairs(files)
    if args.attribution:
        files["ATTRIBUTION.md"] = Path(args.attribution).read_bytes()
    manifest = {
        "schema": SCHEMA,
        "id": args.id,
        "version": args.version,
        "kind": "labpbr",
        "tranche": args.tranche,
        "games": sorted(set(args.game)),
        "source": {
            "package": args.source_package,
            "release": args.source_release,
            "archive_sha256": args.source_sha256,
        },
        "pipeline": {"version": args.pipeline_version},
        "texture_pairs": len(stems),
        "files": [],
    }
    for name, data in sorted(files.items()):
        manifest["files"].append({"path": name, "bytes": len(data), "sha256": digest(data)})
    files["manifest.json"] = canonical_json(manifest)
    archive_data = zip_bytes(files)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(archive_data)
    # Building does not write the catalogue. Where a bundle is published is
    # not known until it is published, and letting build guess produced a
    # relative url that only resolved while the catalogue sat beside the
    # archives. Run the catalogue command with --base-url instead.
    print(f"built {output}: {len(stems)} pairs, {len(archive_data)} bytes, "
          f"sha256 {digest(archive_data)}")


def catalogue_entry(path, base_url):
    """One catalogue row, derived from a built archive rather than restated.

    read_bundle re-checks the manifest and every payload hash, so a row can
    only describe an archive that is actually intact.
    """
    archive = Path(path)
    blob = archive.read_bytes()
    manifest, files = read_bundle(archive)
    url = archive.name
    if base_url:
        url = base_url.rstrip("/") + "/" + archive.name
    return {
        "id": manifest["id"], "version": manifest["version"],
        "games": manifest["games"], "tranche": manifest["tranche"],
        "url": url, "bytes": len(blob), "sha256": digest(blob),
        "provides": validate_pairs(files),
    }


def merge_entry(catalogue, entry):
    catalogue["bundles"] = [row for row in catalogue.get("bundles", [])
                            if row.get("id") != entry["id"]
                            or row.get("version") != entry["version"]]
    catalogue["bundles"].append(entry)
    catalogue["bundles"].sort(key=lambda row: (row["id"], row["version"]))
    return catalogue


def catalogue(args):
    """Point the catalogue at where these archives are published.

    Entries for bundles not named here are left alone, so an epoch that
    changes two bundles re-points two rows and the rest keep pointing at the
    release they were published in. That is what makes an unchanged bundle
    free to leave alone rather than re-uploaded.
    """
    path = Path(args.output)
    data = {"schema": CATALOGUE_SCHEMA, "bundles": []}
    if path.exists():
        data = json.loads(path.read_text())
        if data.get("schema") != CATALOGUE_SCHEMA:
            raise ValueError("unsupported catalogue schema")
    for name in args.archives:
        entry = catalogue_entry(name, args.base_url)
        merge_entry(data, entry)
        print(f"catalogued {entry['id']} {entry['version']} -> {entry['url']}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(data))
    print(f"wrote {path}: {len(data['bundles'])} bundles")


def read_bundle(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("duplicate archive member")
        for name in names:
            pure = PurePosixPath(name)
            if pure.is_absolute() or ".." in pure.parts or str(pure) != name:
                raise ValueError(f"unsafe archive member: {name}")
        files = {name: archive.read(name) for name in names}
    manifest = json.loads(files.pop("manifest.json"))
    if manifest.get("schema") != SCHEMA:
        raise ValueError("unsupported bundle schema")
    declared = {row["path"]: row for row in manifest.get("files", [])}
    if set(declared) != set(files):
        raise ValueError("manifest file list does not match archive")
    for name, data in files.items():
        row = declared[name]
        if row["bytes"] != len(data) or row["sha256"] != digest(data):
            raise ValueError(f"content mismatch: {name}")
    stems = validate_pairs(files)
    if manifest.get("texture_pairs") != len(stems):
        raise ValueError("texture pair count mismatch")
    return manifest, files


def verify(args):
    manifest, _ = read_bundle(args.bundle)
    if args.sha256 and digest(Path(args.bundle).read_bytes()) != args.sha256.lower():
        raise ValueError("archive SHA-256 mismatch")
    print(f"verified {manifest['id']} {manifest['version']}: {manifest['texture_pairs']} pairs")


def install(args):
    manifest, files = read_bundle(args.bundle)
    root = Path(args.root)
    destination = root / manifest["id"] / manifest["version"]
    staging = root / f".{manifest['id']}-{manifest['version']}.installing"
    if staging.exists():
        shutil.rmtree(staging)
    for name, data in files.items():
        target = staging / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    (staging / "manifest.json").write_bytes(canonical_json(manifest))
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        shutil.rmtree(destination)
    staging.replace(destination)
    for game in manifest["games"]:
        compose_profile(root, game)
    print(f"installed {manifest['id']} {manifest['version']} at {destination}")


def version_key(version):
    head = version.split("+", 1)[0]
    return tuple(int(part) if part.isdigit() else 0 for part in head.split(".")) + (version,)


def compose_profile(root, game):
    selected = []
    for bundle_root in sorted(path for path in root.iterdir()
                              if path.is_dir() and path.name != "profiles" and not path.name.startswith(".")):
        compatible = []
        for version_root in bundle_root.iterdir():
            manifest_path = version_root / "manifest.json"
            if not manifest_path.is_file():
                continue
            manifest = json.loads(manifest_path.read_text())
            if manifest.get("schema") == SCHEMA and game in manifest.get("games", []):
                compatible.append((version_key(manifest["version"]), version_root, manifest))
        if compatible:
            selected.append(max(compatible, key=lambda row: row[0])[1:])
    if not selected:
        return
    profile = root / "profiles" / game
    staging = root / "profiles" / f".{game}.installing"
    if staging.exists():
        shutil.rmtree(staging)
    textures = staging / "textures"
    textures.mkdir(parents=True)
    owners = {}
    used = []
    for bundle_root, manifest in selected:
        used.append({"id": manifest["id"], "version": manifest["version"]})
        for source in sorted((bundle_root / "textures").glob("*.png")):
            if source.name in owners:
                raise ValueError(f"asset collision: {source.name} from {owners[source.name]} and {manifest['id']}")
            owners[source.name] = manifest["id"]
            shutil.copyfile(source, textures / source.name)
    (staging / "manifest.json").write_bytes(canonical_json({
        "schema": "org.goanna.asset-profile/v1", "game": game,
        "bundles": used, "textures": len(owners)}))
    if profile.exists():
        shutil.rmtree(profile)
    staging.replace(profile)


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    build_p = commands.add_parser("build")
    build_p.add_argument("--textures", required=True)
    build_p.add_argument("--quality")
    build_p.add_argument("--attribution")
    build_p.add_argument("--id", required=True)
    build_p.add_argument("--version", required=True)
    build_p.add_argument("--tranche", required=True)
    build_p.add_argument("--game", action="append", required=True)
    build_p.add_argument("--source-package", required=True)
    build_p.add_argument("--source-release", required=True)
    build_p.add_argument("--source-sha256", required=True)
    build_p.add_argument("--pipeline-version", required=True)
    build_p.add_argument("--output", required=True)
    build_p.set_defaults(func=build)
    verify_p = commands.add_parser("verify")
    verify_p.add_argument("bundle")
    verify_p.add_argument("--sha256")
    verify_p.set_defaults(func=verify)
    catalogue_p = commands.add_parser("catalogue")
    catalogue_p.add_argument("archives", nargs="+")
    catalogue_p.add_argument("--output", required=True)
    catalogue_p.add_argument("--base-url",
                             help="published directory the archives sit in; "
                                  "entries become absolute URLs beneath it")
    catalogue_p.set_defaults(func=catalogue)
    install_p = commands.add_parser("install")
    install_p.add_argument("bundle")
    install_p.add_argument("--root", required=True)
    install_p.set_defaults(func=install)
    args = parser.parse_args()
    try:
        args.func(args)
    except (OSError, ValueError, KeyError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
