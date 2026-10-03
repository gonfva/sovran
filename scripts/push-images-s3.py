#!/usr/bin/env python3
"""Render a local Docker image as a read-only registry in S3 (PLAN.md Phase 8).

A registry is only a set of HTTP GETs: `/v2/<repo>/manifests/<ref>` and
`/v2/<repo>/blobs/<digest>`. S3 can serve exactly that from static objects, which is how
Phase 8 deletes the ecr.api + ecr.dkr interface endpoints and — the actual prize — lets
the S3 gateway endpoint policy stop allowing the AWS-owned ECR layer bucket.

Usage:
    export AWS_PROFILE=sovran-ref
    scripts/push-images-s3.py --bucket sovran-<acct>-registry --region eu-west-2 \\
        sovran/netcheck:spike
    scripts/push-images-s3.py --bucket ... --region ... --render-only /tmp/reg \\
        sovran/agent:v0.4          # inspect the layout without uploading

Prints one line per image:
    <bucket>.s3.<region>.amazonaws.com/<repo>@sha256:<hex>
which is the digest-pinned reference to paste into terraform.tfvars.

Why no skopeo/crane: neither is installed on the operator machine, and the whole job is
"gzip four files, rewrite a JSON document, upload with the right Content-Type". Adding a
Go binary to hide 200 lines of stdlib is a worse trade than reading them. Only the AWS
CLI and docker are required.

## Pull by digest, always

S3 cannot set the `Docker-Content-Digest` response header — it controls only Content-Type,
Content-Encoding, Content-Language, Content-Disposition, Cache-Control and Expires. A
client resolving a *tag* wants that header to learn what it just fetched. A client pulling
by *digest* already knows, and verifies the bytes it gets against the digest it asked for.
So digest references are not a stylistic preference here, they are the mechanism that makes
a header-less registry sound. Tags are still written (cheap, and they make `aws s3 ls`
readable) but nothing should reference them.

## Docker v2s2, not OCI

Docker 25+ with the containerd image store makes `docker save` emit an OCI layout with
*uncompressed* layers (`application/vnd.oci.image.layer.v1.tar`). Registries serve gzipped
layers, so this script gzips each one and rewrites its descriptor — exactly what a real
`docker push` does on the wire. The config blob is untouched: `rootfs.diff_ids` are digests
of the *uncompressed* tars, so compressing layers cannot invalidate it.

The manifest is then emitted as Docker v2s2 rather than OCI. Both are accepted by
containerd, but S3 ignores the client's `Accept` header, so it cannot negotiate — it serves
one document to everyone. v2s2 is the format every client understands, which makes it the
right single answer. Rewriting the media types changes the manifest bytes and therefore its
digest; that new digest is what gets printed and pinned.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

MANIFEST_V2 = "application/vnd.docker.distribution.manifest.v2+json"
CONFIG_V1 = "application/vnd.docker.container.image.v1+json"
LAYER_GZIP = "application/vnd.docker.image.rootfs.diff.tar.gzip"
BLOB_TYPE = "application/octet-stream"

# Layer media types that are already compressed and must be passed through untouched.
COMPRESSED_LAYERS = {
    "application/vnd.oci.image.layer.v1.tar+gzip",
    "application/vnd.docker.image.rootfs.diff.tar.gzip",
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def run(cmd: list[str]) -> None:
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr.strip()}"
        )


def sha256_file(path: Path) -> tuple[str, int]:
    h = hashlib.sha256()
    size = 0
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
            size += len(chunk)
    return f"sha256:{h.hexdigest()}", size


def docker_save(image: str, dest: Path) -> None:
    """Export the image and unpack it into dest."""
    log(f"==> docker save {image}")
    proc = subprocess.Popen(["docker", "save", image], stdout=subprocess.PIPE)
    assert proc.stdout is not None
    # Streamed rather than written to a temp tar: the agent image is a few hundred MB and
    # there is no reason for it to touch the disk twice.
    with tarfile.open(fileobj=proc.stdout, mode="r|") as tf:
        # filter="data" refuses absolute paths and ../ escapes. It landed in 3.12 and
        # becomes the default later; extractall is a real extraction of a file we did not
        # write, so ask for it when it exists rather than when the interpreter forces it.
        try:
            tf.extractall(dest, filter="data")
        except TypeError:
            tf.extractall(dest)
    if proc.wait() != 0:
        raise SystemExit(f"docker save {image} failed")


def read_source_manifest(layout: Path) -> tuple[dict, dict]:
    """Return (config_descriptor, layer_descriptors) from an unpacked docker save.

    Handles both shapes docker can produce: the OCI layout (index.json -> manifest blob)
    and the legacy docker-archive (manifest.json with Config/Layers paths). Which one you
    get depends on whether the containerd image store is enabled, which is not something
    an operator should have to know before running this.
    """
    index = layout / "index.json"
    if index.exists():
        idx = json.loads(index.read_text())
        manifests = idx.get("manifests", [])
        if len(manifests) != 1:
            raise SystemExit(
                f"expected exactly 1 manifest in index.json, found {len(manifests)}. "
                "Multi-arch images are out of scope: a manifest list adds an indirection "
                "this registry has no reason to serve. Build single-arch (--platform)."
            )
        desc = manifests[0]
        if "index" in desc.get("mediaType", ""):
            raise SystemExit(
                "index.json points at a nested image index (multi-arch). Build single-arch."
            )
        blob = layout / "blobs" / "sha256" / desc["digest"].split(":", 1)[1]
        man = json.loads(blob.read_text())
        return man["config"], man["layers"]

    legacy = layout / "manifest.json"
    if not legacy.exists():
        raise SystemExit(f"{layout} is neither an OCI layout nor a docker archive")
    entries = json.loads(legacy.read_text())
    if len(entries) != 1:
        raise SystemExit(f"expected 1 image in manifest.json, found {len(entries)}")
    entry = entries[0]
    cfg_path = layout / entry["Config"]
    cfg_digest, cfg_size = sha256_file(cfg_path)
    config = {"digest": cfg_digest, "size": cfg_size, "_path": entry["Config"]}
    layers = []
    for rel in entry["Layers"]:
        digest, size = sha256_file(layout / rel)
        layers.append(
            {
                "mediaType": "application/vnd.oci.image.layer.v1.tar",
                "digest": digest,
                "size": size,
                "_path": rel,
            }
        )
    return config, layers


def blob_path(layout: Path, desc: dict) -> Path:
    """Locate a descriptor's bytes in either layout shape."""
    if "_path" in desc:
        return layout / desc["_path"]
    return layout / "blobs" / "sha256" / desc["digest"].split(":", 1)[1]


def gzip_layer(src: Path, dest_dir: Path) -> tuple[str, int, Path]:
    """Compress an uncompressed layer tar; return its registry digest, size and path."""
    tmp = dest_dir / (src.name + ".gz")
    h = hashlib.sha256()
    size = 0
    with src.open("rb") as fin, tmp.open("wb") as raw:
        # mtime=0 so the same layer produces the same digest on every run. With the clock
        # in the gzip header, re-pushing an unchanged image would mint a new digest and
        # silently invalidate whatever tfvars pinned the old one.
        with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=6, mtime=0) as gz:
            while True:
                chunk = fin.read(1024 * 1024)
                if not chunk:
                    break
                gz.write(chunk)
        raw.flush()
    with tmp.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
            size += len(chunk)
    return f"sha256:{h.hexdigest()}", size, tmp


def build_registry(image: str, repo: str, tag: str, workdir: Path, out: Path) -> str:
    """Render `image` into `out` as a /v2/ registry tree. Returns the manifest digest."""
    layout = workdir / "layout"
    layout.mkdir(parents=True, exist_ok=True)
    docker_save(image, layout)

    config_desc, layer_descs = read_source_manifest(layout)

    repo_root = out / "v2" / repo
    blobs_dir = repo_root / "blobs"
    manifests_dir = repo_root / "manifests"
    blobs_dir.mkdir(parents=True, exist_ok=True)
    manifests_dir.mkdir(parents=True, exist_ok=True)

    # /v2/ itself. Clients that probe the API root get a valid empty JSON document; the
    # ones that matter here (containerd) go straight to the manifest and never ask.
    (out / "v2" / "_root.json").write_text("{}")

    cfg_src = blob_path(layout, config_desc)
    cfg_digest, cfg_size = sha256_file(cfg_src)
    shutil.copyfile(cfg_src, blobs_dir / cfg_digest)
    log(f"    config {cfg_digest} ({cfg_size} B)")

    out_layers = []
    for desc in layer_descs:
        src = blob_path(layout, desc)
        if desc.get("mediaType") in COMPRESSED_LAYERS:
            digest, size = desc["digest"], desc["size"]
            shutil.copyfile(src, blobs_dir / digest)
            log(f"    layer  {digest} ({size} B, already gzipped)")
        else:
            digest, size, tmp = gzip_layer(src, workdir)
            shutil.move(str(tmp), blobs_dir / digest)
            log(f"    layer  {digest} ({size} B, gzipped from {desc['size']} B)")
        out_layers.append({"mediaType": LAYER_GZIP, "size": size, "digest": digest})

    manifest = {
        "schemaVersion": 2,
        "mediaType": MANIFEST_V2,
        "config": {"mediaType": CONFIG_V1, "size": cfg_size, "digest": cfg_digest},
        "layers": out_layers,
    }
    # These exact bytes are both hashed and uploaded. Serialising twice with different
    # separators would produce a digest that does not match the object.
    manifest_bytes = json.dumps(manifest, indent=3).encode()
    manifest_digest = "sha256:" + hashlib.sha256(manifest_bytes).hexdigest()

    (manifests_dir / manifest_digest).write_bytes(manifest_bytes)
    (manifests_dir / tag).write_bytes(manifest_bytes)
    log(f"    manifest {manifest_digest} ({len(manifest_bytes)} B), tag {tag}")
    return manifest_digest


def upload(out: Path, bucket: str, region: str, profile: str | None) -> None:
    """Upload the rendered tree, giving every key the Content-Type a registry would send."""
    base = ["aws", "s3api", "put-object", "--bucket", bucket, "--region", region]
    if profile:
        base += ["--profile", profile]

    for path in sorted(out.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(out).as_posix()
        if rel == "v2/_root.json":
            key, ctype = "v2/", "application/json"
        elif "/manifests/" in rel:
            key, ctype = rel, MANIFEST_V2
        else:
            key, ctype = rel, BLOB_TYPE
        log(f"    put s3://{bucket}/{key}  [{ctype}]")
        # No --no-cli-pager: it is AWS CLI v2 only and the operator machine may be on v1.
        # run() captures stdout anyway, so there is nothing for a pager to page.
        run(base + ["--key", key, "--body", str(path), "--content-type", ctype])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("images", nargs="+", metavar="IMAGE[:TAG]",
                    help="local docker image reference, e.g. sovran/netcheck:spike")
    ap.add_argument("--bucket", help="registry bucket (omit only with --render-only)")
    ap.add_argument("--region", default=os.environ.get("AWS_DEFAULT_REGION", "eu-west-2"))
    ap.add_argument("--profile", default=os.environ.get("AWS_PROFILE"))
    ap.add_argument("--tag", help="registry tag to write (default: the image's own tag)")
    ap.add_argument("--render-only", metavar="DIR",
                    help="write the registry tree here and skip the upload")
    args = ap.parse_args()

    if not args.bucket and not args.render_only:
        ap.error("--bucket is required unless --render-only is given")

    out_root = Path(args.render_only) if args.render_only else None
    refs = []

    for image in args.images:
        repo, _, image_tag = image.partition(":")
        tag = args.tag or image_tag or "latest"
        log(f"==> {image} -> {repo}:{tag}")

        with tempfile.TemporaryDirectory(prefix="sovran-reg-") as tmp:
            workdir = Path(tmp)
            out = out_root / repo.replace("/", "_") if out_root else workdir / "out"
            out.mkdir(parents=True, exist_ok=True)
            digest = build_registry(image, repo, tag, workdir, out)
            if args.bucket:
                upload(out, args.bucket, args.region, args.profile)
                refs.append(f"{args.bucket}.s3.{args.region}.amazonaws.com/{repo}@{digest}")
            else:
                refs.append(f"{out}  ({repo}@{digest})")

    log("")
    for ref in refs:
        print(ref)
    return 0


if __name__ == "__main__":
    sys.exit(main())
