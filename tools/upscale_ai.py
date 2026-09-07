#!/usr/bin/env python3
"""Real-ESRGAN (ncnn-vulkan) helper for the asset importer.

The original sprites are tiny 3D renders (penguins are 80x60); plain resampling can only blur
them. Real-ESRGAN synthesises real edge detail, so `import_assets.py` runs every sprite
sequence and every small still through it (4x) and resamples that to the HD factor. Results
are cached under `boreal_bounce/.cache/esrgan/` keyed by content hash, so the GPU pass runs
once (a few minutes for the ~3200 images) and later imports are instant.

Requirements: a Vulkan-capable GPU (the binary has no CPU mode) and the prebuilt binary in
`tools/esrgan/` (`python tools/upscale_ai.py --install` downloads it, ~45 MB, BSD-3 licensed,
models included).

The binary is fragile, and the workarounds here are all load-bearing:
- it only gets 3-channel RGB (colours bled under transparent pixels first); alpha is upscaled
  here with bicubic and merged back. Its own alpha path returns blank images for art without
  any fully opaque pixel (the menu plates) and produced garbage after tiny inputs;
- tiny images are padded to 32 px (it hangs on a 7x7 dot);
- fixed tile size and one processing thread, small batches, every result verified by
  downsampling it against its input, failures retried in smaller batches;
- it often never exits after writing the last output (busy thread, GPU idle), so completion
  is detected from the output files and the process is then killed.

Standalone use: python tools/upscale_ai.py in.png out.png [--scale 4] [--model NAME]
"""
import hashlib
import io
import platform
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
BIN_DIR = HERE / "esrgan"
CACHE_DIR = HERE.parent / ".cache" / "esrgan"
RELEASE = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-{os}.zip"
DEFAULT_MODEL = "realesrgan-x4plus-anime"  # crispest on the Blender-rendered sprites
MODEL_SCALE = 4  # every bundled x4 model outputs 4x
MIN_SIDE = 32  # pad smaller inputs (the binary hangs on tiny images), crop afterwards


def binary_path() -> Path:
    return BIN_DIR / ("realesrgan-ncnn-vulkan.exe" if platform.system() == "Windows" else "realesrgan-ncnn-vulkan")


def ensure_binary(download: bool) -> Path | None:
    """Path of the upscaler binary, downloading the release zip when allowed and missing."""
    exe = binary_path()
    if exe.exists() and (BIN_DIR / "models").is_dir():
        return exe
    if not download:
        return None
    os_name = {"Linux": "ubuntu", "Windows": "windows", "Darwin": "macos"}.get(platform.system())
    if os_name is None:
        return None
    url = RELEASE.format(os=os_name)
    print(f"downloading {url}")
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for member in z.namelist():
            if member.endswith("/") or member.startswith("input"):
                continue
            target = BIN_DIR / member
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(z.read(member))
    if not exe.exists():
        return None
    exe.chmod(0o755)
    return exe


def bleed_colours(a: np.ndarray, passes: int = 24) -> np.ndarray:
    """Copy edge colours into fully transparent pixels (GIF frames keep white there), so the
    network and later linear filtering never mix in a foreign colour at the outline."""
    if a.shape[2] < 4:
        return a
    alpha = a[..., 3] > 0
    if alpha.all():
        return a
    rgb = a[..., :3].astype(np.float32)
    filled = alpha.copy()
    rgb[~filled] = 0.0
    for _ in range(passes):
        if filled.all():
            break
        pad_rgb = np.pad(rgb, ((1, 1), (1, 1), (0, 0)))
        pad_f = np.pad(filled, 1).astype(np.float32)
        acc = np.zeros_like(rgb)
        cnt = np.zeros(filled.shape, np.float32)
        h, w = filled.shape
        for dy in (0, 1, 2):
            for dx in (0, 1, 2):
                if dy == 1 and dx == 1:
                    continue
                acc += pad_rgb[dy:dy + h, dx:dx + w] * pad_f[dy:dy + h, dx:dx + w, None]
                cnt += pad_f[dy:dy + h, dx:dx + w]
        new = (~filled) & (cnt > 0)
        rgb[new] = acc[new] / cnt[new][:, None]
        filled |= new
    if not filled.all():
        mean = rgb[alpha].mean(axis=0) if alpha.any() else np.zeros(3, np.float32)
        rgb[~filled] = mean
    out = a.copy()
    out[..., :3] = (rgb + 0.5).astype(np.uint8)
    return out


def prepare(path: Path) -> tuple:
    """(rgb, alpha) upscaler inputs: colours bled under transparency, padded to MIN_SIDE."""
    im = Image.open(path).convert("RGBA")
    if im.width < MIN_SIDE or im.height < MIN_SIDE:
        padded = Image.new("RGBA", (max(im.width, MIN_SIDE), max(im.height, MIN_SIDE)), (0, 0, 0, 0))
        padded.paste(im, (0, 0))
        im = padded
    bled = Image.fromarray(bleed_colours(np.asarray(im)), "RGBA")
    return bled.convert("RGB"), bled.getchannel("A")


class Upscaler:
    """Batch front-end: request(key, source) many times, then run() once; get(key) -> Path."""

    CHUNK = 64
    TILE = 100
    MAX_ERR = 40.0  # mean abs RGB difference allowed between the box-downsampled result and its
    # input; real results score under 25 (tiny detailed icons highest), garbage 80 and up

    def __init__(self, model: str = DEFAULT_MODEL, download: bool = False, cache_dir: Path = CACHE_DIR):
        self.model = model
        self.exe = ensure_binary(download)
        self.cache = cache_dir / f"{model}-x{MODEL_SCALE}"
        self.jobs = {}  # key -> (source path, cache path)
        self.extra_args = []
        self.failed = []

    @property
    def available(self) -> bool:
        return self.exe is not None

    @staticmethod
    def _hash(path: Path) -> str:
        return hashlib.md5(path.read_bytes()).hexdigest()[:10]

    def request(self, key: str, source: Path) -> None:
        name = key.replace("/", "__").replace("\\", "__") + "-" + self._hash(source) + ".png"
        self.jobs[key] = (source, self.cache / name)

    def _invoke(self, tmp_in: Path, tmp_out: Path, names: list, log) -> None:
        """Run the binary over tmp_in; completion detected from the outputs (see module doc)."""
        cmd = [str(self.exe), "-i", str(tmp_in), "-o", str(tmp_out), "-n", self.model, "-s", str(MODEL_SCALE),
               "-m", str(BIN_DIR / "models"), "-f", "png", "-t", str(self.TILE), "-j", "1:1:1"] + list(self.extra_args)
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            log(f"  upscaler failed to start: {e}")
            return
        expected = [tmp_out / n for n in names]
        deadline = time.monotonic() + 60.0 + 3.0 * len(expected)
        last_sizes = None
        stable_since = None
        while proc.poll() is None:
            sizes = tuple(p.stat().st_size if p.exists() else -1 for p in expected)
            if all(sz > 0 for sz in sizes):
                if sizes == last_sizes:
                    if stable_since is None:
                        stable_since = time.monotonic()
                    elif time.monotonic() - stable_since > 2.0:
                        break
                else:
                    stable_since = None
            last_sizes = sizes
            if time.monotonic() > deadline:
                log(f"  upscaler stalled on a batch of {len(expected)}; killing it")
                break
            time.sleep(0.25)
        if proc.poll() is None:
            proc.kill()
            proc.wait()

    @classmethod
    def plausible(cls, rgb_in: Image.Image, out: Image.Image) -> bool:
        """Reject corrupted results: downsampled back, a real upscale stays close to its input."""
        if out.size != (rgb_in.width * MODEL_SCALE, rgb_in.height * MODEL_SCALE):
            return False
        src = np.asarray(rgb_in.convert("RGB")).astype(np.float32)
        small = np.asarray(out.convert("RGB").resize(rgb_in.size, Image.BOX)).astype(np.float32)
        return float(np.abs(small - src).mean()) <= cls.MAX_ERR

    def run(self, log=print) -> None:
        """Upscale every requested image that is not cached yet."""
        todo = [(src, dst) for src, dst in self.jobs.values() if not dst.exists()]
        if not todo:
            return
        if self.exe is None:
            self.failed = [k for k, (_, dst) in self.jobs.items() if not dst.exists()]
            return
        self.cache.mkdir(parents=True, exist_ok=True)
        log(f"Real-ESRGAN {self.model}: upscaling {len(todo)} images ({len(self.jobs) - len(todo)} cached)")
        tmp_in = self.cache.parent / "tmp_in"
        tmp_out = self.cache.parent / "tmp_out"
        queue = list(todo)
        chunk = self.CHUNK
        done = reported = 0
        while queue:
            batch, queue = queue[:chunk], queue[chunk:]
            for d in (tmp_in, tmp_out):
                shutil.rmtree(d, ignore_errors=True)
                d.mkdir(parents=True)
            prepared = {}
            for src, dst in batch:
                prepared[dst.name] = prepare(src)
                prepared[dst.name][0].save(tmp_in / dst.name, format="PNG")
            self._invoke(tmp_in, tmp_out, [dst.name for _, dst in batch], log)
            bad = []
            for src, dst in batch:
                rgb_in, alpha_in = prepared[dst.name]
                out = None
                if (tmp_out / dst.name).exists():
                    try:
                        out = Image.open(tmp_out / dst.name).convert("RGB")
                    except OSError:
                        out = None
                if out is None or not self.plausible(rgb_in, out):
                    bad.append((src, dst))
                    continue
                out.putalpha(alpha_in.resize(out.size, Image.BICUBIC))
                w, h = Image.open(src).size
                if out.size != (w * MODEL_SCALE, h * MODEL_SCALE):  # padded tiny image
                    out = out.crop((0, 0, w * MODEL_SCALE, h * MODEL_SCALE))
                out.save(dst, format="PNG")
                done += 1
            if bad and len(batch) > 1:
                chunk = max(1, chunk // 2)
                queue = bad + queue  # retry those in smaller batches
                log(f"  {len(bad)} of {len(batch)} results failed verification; retrying with batches of {chunk}")
            elif not bad:
                chunk = min(self.CHUNK, chunk * 2)
            if done - reported >= 500:
                reported = done
                log(f"  {done}/{len(todo)}")
        for d in (tmp_in, tmp_out):
            shutil.rmtree(d, ignore_errors=True)
        self.failed = [k for k, (_, dst) in self.jobs.items() if not dst.exists()]
        if self.failed:
            log(f"  {len(self.failed)} images not upscaled (falling back to Lanczos)")

    def get(self, key: str) -> Path | None:
        entry = self.jobs.get(key)
        return entry[1] if entry and entry[1].exists() else None


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", nargs="?")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--install", action="store_true", help="download the Real-ESRGAN binary into tools/esrgan/")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--scale", type=int, default=MODEL_SCALE, help="output factor (the model's 4x is resampled to it)")
    args = ap.parse_args()
    if args.install:
        exe = ensure_binary(True)
        sys.exit(0 if exe else "download failed")
    if not (args.src and args.dst):
        ap.error("src and dst are required")
    up = Upscaler(args.model, download=True)
    src = Path(args.src)
    up.request(src.name, src)
    up.run()
    out = up.get(src.name)
    if out is None:
        sys.exit("upscale failed")
    im = Image.open(out).convert("RGBA")
    if args.scale != MODEL_SCALE:
        w, h = Image.open(src).size
        im = im.resize((w * args.scale, h * args.scale), Image.LANCZOS)
    im.save(args.dst, format="PNG")
    print(f"wrote {args.dst} {im.size}")


if __name__ == "__main__":
    main()
