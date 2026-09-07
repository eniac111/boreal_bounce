#!/usr/bin/env python3
"""Import Frozen-Bubble's `share/` tree into Boreal Bounce's `assets/` directory.

Idempotent: wipes and regenerates every generated directory under assets/ (fonts/ is kept, it is
hand-curated). Run from anywhere:

    python3 tools/import_assets.py [--share PATH] [--assets PATH]

What it does:
  gfx/     PNGs copied as-is; GIFs converted to PNG; numbered frame sequences
           (name_0001.png ...) packed into one sprite sheet + a SpriteFrames .tres resource.
  snd/     copied (ogg).
  data/    levels -> assets/levels/default-levelset.lvl (format unchanged).
  locale/  .po/.pot copied (Godot imports gettext natively).
  icons/   copied, "frozen-bubble-" prefix dropped.
  gfx/font*.png  converted to BMFont via sfont_to_fnt.py into assets/fonts/bitmap/.
Writes assets/PROVENANCE.md listing every source -> destination mapping.
"""
import argparse
import json
import subprocess
import os
import math
import re
import shutil
import sys
from collections import defaultdict
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sfont_to_fnt import convert as convert_sfont  # noqa: E402

SEQ_RE = re.compile(r"^(?P<base>.+?)_(?P<idx>\d+)\.png$")
SFONTS = {"font.png": "editor", "font2.png": "editor_alt", "font-hi.png": "editor_hi"}
FRAME_FPS = 50.0  # one animation frame per game frame (20 ms) in the original


MATTE_WHITE = 255.0
MATTE_MIN_LIFT = 10.0  # a rim pixel must be this much lighter than the shape to count as matte
CLEAN_CACHE = None  # set in main(): un-matted copies of the share/ frames
clean_stats = [0, 0]  # images seen, images changed


def _neighbour_mean(rgb, mask):
    """Mean colour of the masked pixels around each pixel (3x3, falling back to 5x5)."""
    import numpy as np
    h, w = mask.shape
    m = mask.astype(np.float32)
    best_acc = best_cnt = None
    for r in (1, 2):
        acc = np.zeros((h, w, 3), np.float32)
        cnt = np.zeros((h, w), np.float32)
        pr = np.pad(rgb, ((r, r), (r, r), (0, 0)))
        pm = np.pad(m, r)
        for dy in range(2 * r + 1):
            for dx in range(2 * r + 1):
                if dy == r and dx == r:
                    continue
                acc += pr[dy:dy + h, dx:dx + w] * pm[dy:dy + h, dx:dx + w, None]
                cnt += pm[dy:dy + h, dx:dx + w]
        if best_acc is None:
            best_acc, best_cnt = acc, cnt
        else:
            fill = (best_cnt == 0) & (cnt > 0)
            best_acc[fill] = acc[fill]
            best_cnt[fill] = cnt[fill]
    out = np.zeros((h, w, 3), np.float32)
    ok = best_cnt > 0
    out[ok] = best_acc[ok] / best_cnt[ok][:, None]
    return out, ok


def clean_matte(im: Image.Image) -> Image.Image:
    """Undo the white matte baked into the original artwork.

    The sprites were rendered against white and keyed with a coarse mask (their alpha only
    takes the values 0, 128 and 255), which leaves light speckles along the silhouette and a
    hard, aliased outline. For every pixel that is not fully inside the shape, the interior
    colour F is estimated from its neighbours and the stored colour C is read as F composited
    over white: C = a * F + (1 - a) * 255. The least-squares solution for the coverage a gives
    a real antialiased alpha and drops the white rim. Pixels that are not lighter than their
    neighbours (a deliberate white outline like hurry_*.png, or a fully opaque image) come out
    unchanged, because then F is white too and the equation is degenerate.
    """
    import numpy as np
    a = np.asarray(im.convert("RGBA")).astype(np.float32)
    rgb, al = a[..., :3].copy(), a[..., 3].copy()
    opaque = al >= 250
    if not opaque.any():
        return im
    h, w = al.shape
    # pad with the edge value so the image border is not mistaken for a silhouette edge
    pad = np.pad(al, 1, mode="edge")
    near_edge = np.zeros((h, w), bool)
    for dy in (0, 1, 2):
        for dx in (0, 1, 2):
            if dy == 1 and dx == 1:
                continue
            near_edge |= pad[dy:dy + h, dx:dx + w] < 250
    interior = opaque & ~near_edge
    target = (al > 0) & ~interior  # the opaque rim plus the half-transparent fringe
    if not interior.any() or not target.any():
        return im
    F, have = _neighbour_mean(rgb, interior)
    sel = target & have
    if not sel.any():
        return im
    C, Fs = rgb[sel], F[sel]
    d = MATTE_WHITE - Fs
    den = (d * d).sum(axis=1)
    cov = np.clip(np.where(den > 1e-3, ((MATTE_WHITE - C) * d).sum(axis=1) / np.maximum(den, 1e-3), 1.0), 0.0, 1.0)
    lifted = (C - Fs).min(axis=1) > MATTE_MIN_LIFT
    al[sel] = np.minimum(al[sel], np.where(lifted, cov * 255.0, al[sel]))
    rgb[sel] = np.where(lifted[:, None], Fs, C)
    return Image.fromarray(np.clip(np.concatenate([rgb, al[..., None]], axis=2) + 0.5, 0, 255).astype(np.uint8), "RGBA")


def clean_image_file(path: Path) -> bool:
    """Un-matte an imported image in place. Returns True when it changed."""
    import numpy as np
    im = Image.open(path).convert("RGBA")
    out = clean_matte(im)
    clean_stats[0] += 1
    if np.array_equal(np.asarray(im), np.asarray(out)):
        return False
    out.save(path, format="PNG")
    clean_stats[1] += 1
    return True


def cleaned_source(src: Path) -> Path:
    """Un-matted copy of a share/ frame under .cache/clean, or the original when unchanged."""
    import numpy as np
    im = Image.open(src).convert("RGBA")
    out = clean_matte(im)
    clean_stats[0] += 1
    if np.array_equal(np.asarray(im), np.asarray(out)):
        return src
    dst = CLEAN_CACHE / src.relative_to(ROOT_SHARE)
    dst.parent.mkdir(parents=True, exist_ok=True)
    out.save(dst, format="PNG")
    clean_stats[1] += 1
    return dst


def rm_dir(p: Path):
    """Remove generated files but keep Godot's *.import sidecars: without them the game cannot
    load the 1x textures until the editor (or `godot --import`) has run again."""
    if not p.exists():
        return
    for f in sorted(p.rglob("*"), key=lambda x: len(x.parts), reverse=True):
        if f.is_file() and f.suffix != ".import":
            f.unlink()
        elif f.is_dir() and not any(f.iterdir()):
            f.rmdir()


def prune_sidecars(root: Path) -> int:
    """Delete *.import files whose asset no longer exists."""
    n = 0
    for f in sorted(root.rglob("*.import")):
        if not f.with_suffix("").exists():
            f.unlink()
            n += 1
    return n


def copy(src: Path, dst: Path, prov: list, note: str = ""):
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    prov.append((str(src_rel(src)), str(dst_rel(dst)), note))


ROOT_SHARE = None
ROOT_ASSETS = None


def src_rel(p: Path) -> Path:
    try:
        return p.relative_to(ROOT_SHARE)
    except ValueError:  # an un-matted copy in the clean cache: name the share/ original
        return p.relative_to(CLEAN_CACHE)


def dst_rel(p: Path) -> Path:
    return p.relative_to(ROOT_ASSETS)


def gif_to_png(src: Path, dst: Path, prov: list):
    dst.parent.mkdir(parents=True, exist_ok=True)
    Image.open(src).convert("RGBA").save(dst)
    prov.append((str(src_rel(src)), str(dst_rel(dst)), "GIF converted to PNG"))


PAD = 1  # transparent pixels around every frame so linear filtering never bleeds a neighbour
SEQUENCES = {}  # packed sheet path -> {"files", "fw", "fh", "cols"}; import_hd rebuilds sheets from the frames


def write_sprite_frames(tres: Path, sheet_res_path: str, fw: int, fh: int, count: int, cols: int):
    lines = [f'[gd_resource type="SpriteFrames" load_steps={count + 2} format=3]', ""]
    lines.append(f'[ext_resource type="Texture2D" path="{sheet_res_path}" id="1"]')
    lines.append("")
    for i in range(count):
        x = (i % cols) * (fw + 2 * PAD) + PAD
        y = (i // cols) * (fh + 2 * PAD) + PAD
        lines.append(f'[sub_resource type="AtlasTexture" id="Atlas_{i + 1}"]')
        lines.append('atlas = ExtResource("1")')
        lines.append(f"region = Rect2({x}, {y}, {fw}, {fh})")
        lines.append("")
    frames = ", ".join(f'{{\n"duration": 1.0,\n"texture": SubResource("Atlas_{i + 1}")\n}}' for i in range(count))
    lines.append("[resource]")
    lines.append(f'animations = [{{\n"frames": [{frames}],\n"loop": true,\n"name": &"default",\n"speed": {FRAME_FPS}\n}}]')
    tres.write_text("\n".join(lines) + "\n", encoding="utf-8")


def pack_sequence(files: list, dst_png: Path, dst_tres: Path, prov: list, warnings: list):
    imgs = [Image.open(f).convert("RGBA") for f in files]
    sizes = {im.size for im in imgs}
    fw = max(s[0] for s in sizes)
    fh = max(s[1] for s in sizes)
    if len(sizes) > 1:
        warnings.append(f"{files[0].parent.name}/{dst_png.stem}: frames have mixed sizes {sorted(sizes)}, padded to {fw}x{fh}")
    count = len(imgs)
    cols = max(1, min(count, math.ceil(math.sqrt(count))))
    while cols * fw > 4096:
        cols -= 1
    rows = math.ceil(count / cols)
    cw, ch = fw + 2 * PAD, fh + 2 * PAD
    sheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
    for i, im in enumerate(imgs):
        sheet.paste(im, ((i % cols) * cw + PAD, (i // cols) * ch + PAD))
    dst_png.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(dst_png)
    SEQUENCES[dst_png.resolve()] = {"files": list(files), "fw": fw, "fh": fh, "cols": cols}
    write_sprite_frames(dst_tres, "res://assets/" + str(dst_rel(dst_png)).replace("\\", "/"), fw, fh, count, cols)
    dst_png.with_suffix(".sheet.json").write_text(
        '{"frame_w": %d, "frame_h": %d, "count": %d, "columns": %d, "pad": %d}\n' % (fw, fh, count, cols, PAD), encoding="utf-8")
    first, last = files[0].name, files[-1].name
    prov.append((f"{src_rel(files[0].parent)}/{first} .. {last} ({count} frames)", str(dst_rel(dst_png)) + " + " + dst_tres.name,
                 f"sprite sheet {cols}x{rows} of {fw}x{fh}"))


def import_gfx(share: Path, assets: Path, prov: list, warnings: list):
    src_root = share / "gfx"
    dst_root = assets / "gfx"
    rm_dir(dst_root)
    for d in sorted(p for p in src_root.rglob("*") if p.is_dir()) + [src_root]:
        files = sorted(p for p in d.iterdir() if p.is_file())
        groups = defaultdict(list)
        singles = []
        for f in files:
            m = SEQ_RE.match(f.name)
            if m:
                groups[(m.group("base"), len(m.group("idx")))].append(f)
            else:
                singles.append(f)
        for (base, _), seq in sorted(groups.items()):
            if len(seq) < 2:
                singles.extend(seq)
                continue
            seq.sort(key=lambda p: int(SEQ_RE.match(p.name).group("idx")))
            seq = [cleaned_source(f) for f in seq]  # drop the baked white matte before packing
            rel = d.relative_to(src_root)
            pack_sequence(seq, dst_root / rel / f"{base}.png", dst_root / rel / f"{base}.tres", prov, warnings)
        for f in singles:
            rel = f.relative_to(src_root)
            if f.name in SFONTS and d == src_root:
                continue  # handled by import_fonts
            if f.suffix.lower() == ".gif":
                out = (dst_root / rel).with_suffix(".png")
                gif_to_png(f, out, prov)
                clean_image_file(out)
            elif f.suffix.lower() in (".png", ".bmp"):
                out = dst_root / rel
                copy(f, out, prov)
                if f.suffix.lower() == ".png":
                    clean_image_file(out)
            else:
                warnings.append(f"skipped unknown gfx file {rel}")


def import_fonts(share: Path, assets: Path, prov: list):
    dst = assets / "fonts" / "bitmap"
    rm_dir(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for name, face in SFONTS.items():
        src = share / "gfx" / name
        n = convert_sfont(src, dst / f"{face}.png", dst / f"{face}.fnt", face)
        prov.append((str(src_rel(src)), f"fonts/bitmap/{face}.fnt + {face}.png", f"SFont -> BMFont, {n} glyphs"))


def import_plain(share: Path, assets: Path, sub: str, dst_sub: str, prov: list, rename=lambda n: n, exts=None):
    src = share / sub
    dst = assets / dst_sub
    rm_dir(dst)
    for f in sorted(src.iterdir()):
        if f.is_file() and (exts is None or f.suffix.lower() in exts):
            copy(f, dst / rename(f.name), prov)


def import_locale(share: Path, assets: Path, prov: list, warnings: list):
    """Copy gettext files, transcoding the few ISO-8859-1 ones to UTF-8 (Godot requires UTF-8)."""
    src = share / "locale"
    dst = assets / "locale"
    rm_dir(dst)
    dst.mkdir(parents=True, exist_ok=True)
    for f in sorted(src.iterdir()):
        if f.suffix.lower() not in (".po", ".pot"):
            continue
        raw = f.read_bytes()
        note = ""
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            m = re.search(rb"charset=([\w-]+)", raw[:1000])
            enc = m.group(1).decode() if m else "iso-8859-1"
            text = raw.decode(enc)
            text = re.sub(r"charset=[\w-]+", "charset=UTF-8", text, count=1)
            note = f"transcoded from {enc} to UTF-8"
        if f.suffix.lower() == ".po" and not re.search(r'^"Language:', text, re.M):
            # Godot reads the locale from the gettext "Language:" header; these old files lack it.
            text = text.replace('"Content-Type:', f'"Language: {f.stem}\\n"\n"Content-Type:', 1)
            note = (note + "; " if note else "") + "added Language header"
        (dst / f.name).write_text(text, encoding="utf-8")
        prov.append((str(src_rel(f)), f"locale/{f.name}", note))


def import_clean_panels(share: Path, assets: Path, prov: list):
    """Logo-free version of the wooden menu panel (void_panel.png / 1p_panel.png have the
    Frozen-Bubble logo engraved). Keeps the original border and fills the interior with
    procedurally generated wood in the panel's own colours (deterministic seed)."""
    import numpy as np
    src = share / "gfx" / "menu" / "void_panel.png"
    im = Image.open(src).convert("RGBA")
    w, h = im.size
    border = 12
    inner = np.asarray(im)[border:h - border, border:w - border, :3].astype(np.float32)
    dark = np.percentile(inner.reshape(-1, 3), 15, axis=0)
    light = np.percentile(inner.reshape(-1, 3), 85, axis=0)
    iw, ih = w - 2 * border, h - 2 * border
    rng = np.random.default_rng(1234)

    def smooth_noise(cols, rows, scale):
        small = rng.random((max(2, rows // scale), max(2, cols // scale))).astype(np.float32)
        return np.asarray(Image.fromarray((small * 255).astype(np.uint8), "L").resize((cols, rows), Image.BICUBIC)).astype(np.float32) / 255.0

    ys = np.arange(ih)[:, None].astype(np.float32)
    warp = smooth_noise(iw, ih, 48) * 14.0 + smooth_noise(iw, ih, 12) * 4.0
    rings = 0.5 + 0.5 * np.sin((ys + warp) * 0.55)
    fine = smooth_noise(iw, ih, 2) * 0.25
    t = np.clip(rings * 0.75 + fine, 0.0, 1.0)[..., None]
    wood = dark + (light - dark) * t
    out = np.asarray(im).copy()
    out[border:h - border, border:w - border, :3] = np.clip(wood, 0, 255).astype(np.uint8)
    # soften the seam with the border by blending a few pixels inward
    for i in range(4):
        a = (i + 1) / 5.0
        for (y0, y1, x0, x1) in ((border + i, border + i + 1, border, w - border), (h - border - 1 - i, h - border - i, border, w - border),
                                 (border, h - border, border + i, border + i + 1), (border, h - border, w - border - 1 - i, w - border - i)):
            out[y0:y1, x0:x1, :3] = (np.asarray(im)[y0:y1, x0:x1, :3] * (1 - a) + out[y0:y1, x0:x1, :3] * a).astype(np.uint8)
    dst = assets / "gfx" / "menu" / "panel_clean.png"
    Image.fromarray(out, "RGBA").save(dst)
    prov.append((str(src_rel(src)), "gfx/menu/panel_clean.png", "logo removed: interior replaced by procedural wood in the same colours"))


HD_SCALE = 2


def upscale_rgba(im: Image.Image, factor: int) -> Image.Image:
    """Lanczos upscale on premultiplied alpha so transparent edges keep their colour."""
    import numpy as np
    a = np.asarray(im.convert("RGBA")).astype(np.float32) / 255.0
    rgb = a[..., :3] * a[..., 3:4]
    pre = np.concatenate([rgb, a[..., 3:4]], axis=2)
    pre_img = Image.fromarray((pre * 255.0 + 0.5).astype(np.uint8), "RGBA")
    big = pre_img.resize((im.width * factor, im.height * factor), Image.LANCZOS)
    b = np.asarray(big).astype(np.float32) / 255.0
    alpha = b[..., 3:4]
    rgb = np.where(alpha > 1e-4, b[..., :3] / np.maximum(alpha, 1e-4), 0.0)
    out = np.concatenate([np.clip(rgb, 0, 1), alpha], axis=2)
    return Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")


AI_MAX_DIM = 512  # stills bigger than this (the 640x480 backgrounds) keep the Lanczos path: the
# network sharpens their dither/interlace pattern into visible stripes


def _resample(im: Image.Image, size: tuple) -> Image.Image:
    return im if im.size == size else im.resize(size, Image.LANCZOS)


def import_hd(assets: Path, prov: list, warnings: list, ai: str = "auto", hd_scale: int = HD_SCALE):
    """Upscaled versions of every gfx image (except shader masks) in assets/gfx_hd/**/name.png.hd.
    The runtime Art loader prefers them, drawn at the original logical size, so big screens
    get real extra resolution. Sprite sequences and small stills go through Real-ESRGAN
    (tools/upscale_ai.py: 4x with synthesised detail, resampled to hd_scale) when the binary
    or its cache is available; everything else is a premultiplied Lanczos upscale. Any integer
    factor works at runtime: the Art loader reports the 1x size from the imported textures."""
    src_root = assets / "gfx"
    dst_root = assets / "gfx_hd"
    rm_dir(dst_root)
    pngs = [p for p in sorted(src_root.rglob("*.png")) if p.relative_to(src_root).parts[0] != "transitions"]
    up = None
    if ai != "off":
        import upscale_ai
        up = upscale_ai.Upscaler(download=(ai == "on"))
        for png in pngs:  # gather every job first so the GPU pass runs once
            key = str(png.relative_to(src_root)).replace("\\", "/")
            seq = SEQUENCES.get(png.resolve())
            if seq:
                for i, f in enumerate(seq["files"]):
                    up.request(f"{key}#{i:04d}", f)
            elif max(Image.open(png).size) <= AI_MAX_DIM:
                up.request(key, png)
        up.run()
        if up.failed:
            how = "binary not installed (run `python tools/upscale_ai.py --install`)" if not up.available else "upscaler failed"
            warnings.append(f"Real-ESRGAN {how}: {len(up.failed)} images/frames are plain Lanczos upscales")
    n_ai = n_lanczos = 0
    sizes = {}  # 1x size of every image, so the Art loader never depends on the 1x import
    for png in pngs:
        rel = png.relative_to(src_root)
        key = str(rel).replace("\\", "/")
        out = dst_root / rel.parent / (rel.name + ".hd")
        out.parent.mkdir(parents=True, exist_ok=True)
        sizes[key] = list(Image.open(png).size)
        seq = SEQUENCES.get(png.resolve())
        if seq:
            s = hd_scale
            fw, fh, cols = seq["fw"], seq["fh"], seq["cols"]
            cw, ch = (fw + 2 * PAD) * s, (fh + 2 * PAD) * s
            rows = math.ceil(len(seq["files"]) / cols)
            sheet = Image.new("RGBA", (cols * cw, rows * ch), (0, 0, 0, 0))
            for i, f in enumerate(seq["files"]):
                frame = Image.open(f).convert("RGBA")
                ai_path = up.get(f"{key}#{i:04d}") if up else None
                if ai_path:
                    big = _resample(Image.open(ai_path).convert("RGBA"), (frame.width * s, frame.height * s))
                    n_ai += 1
                else:
                    big = upscale_rgba(frame, s)
                    n_lanczos += 1
                sheet.paste(big, ((i % cols) * cw + PAD * s, (i // cols) * ch + PAD * s))
            sheet.save(out, format="PNG")
        else:
            im = Image.open(png).convert("RGBA")
            ai_path = up.get(key) if up else None
            if ai_path:
                _resample(Image.open(ai_path).convert("RGBA"), (im.width * hd_scale, im.height * hd_scale)).save(out, format="PNG")
                n_ai += 1
            else:
                upscale_rgba(im, HD_SCALE).save(out, format="PNG")
                n_lanczos += 1
    (dst_root / "manifest.json").write_text(json.dumps(sizes, separators=(",", ":")), encoding="utf-8")
    # The ".hd" extension keeps Godot's texture importer away from these files; they must be
    # added to the export include filter ("*.hd,*.json,*.lvl,*.bbr").
    model = up.model if up else "off"
    prov.append(("assets/gfx/**/*.png", f"gfx_hd/**/*.png.hd ({len(pngs)} files)",
                 f"{n_ai} frames/stills via Real-ESRGAN {model} 4x resampled to {hd_scale}x; {n_lanczos} via {HD_SCALE}x Lanczos (premultiplied alpha)"))


def _dilate(mask, r: int):
    import numpy as np
    out = mask.copy()
    h, w = mask.shape
    pad = np.pad(mask, r)
    for dy in range(2 * r + 1):
        for dx in range(2 * r + 1):
            out |= pad[dy:dy + h, dx:dx + w]
    return out


def remove_baked_version(assets: Path, prov: list, warnings: list):
    """Paint out the "Version 2.213" lettering baked into the menu background.

    It belongs to the original release, not to this fork, and it sits on the plain magenta
    strip down the right edge, below the vine pattern, so the strip's own background colour
    fills it seamlessly. The little iced tower at the top of the same strip is kept: only
    lettering in the lower half is removed.
    """
    import numpy as np
    png = assets / "gfx" / "menu" / "back_start.png"
    if not png.exists():
        warnings.append("menu background missing; baked version text not removed")
        return
    a = np.asarray(Image.open(png).convert("RGB")).astype(int)
    h, w, _ = a.shape
    magenta = (a[..., 0] > 90) & (a[..., 1] < 90) & (a[..., 2] < a[..., 0])
    frac = magenta.mean(axis=0)
    x0 = w
    while x0 > 0 and frac[x0 - 1] >= 0.6:
        x0 -= 1
    if x0 >= w - 8:
        warnings.append("menu background: right-hand strip not found, version text left in place")
        return
    strip = a[:, x0:]
    light = (strip[..., 0] > 170) & (strip[..., 1] > 90) & (strip[..., 2] > 150)
    rows = np.where(light.any(axis=1))[0]
    rows = rows[rows > h // 2]
    if rows.size == 0:
        warnings.append("menu background: no version lettering found on the strip")
        return
    top, bottom = max(int(rows.min()) - 3, 0), min(int(rows.max()) + 3, h - 1)
    colours, counts = np.unique(strip.reshape(-1, 3), axis=0, return_counts=True)
    background = colours[counts.argmax()]
    region = strip[top:bottom + 1]
    off_bg = np.abs(region - background).sum(axis=2) > 12
    other = int((off_bg & ~_dilate(light[top:bottom + 1], 3)).sum())
    if other > 200:  # the vine pattern would be painted over as well
        warnings.append(f"menu background: {other} patterned pixels sit behind the version text; left in place")
        return
    a[top:bottom + 1, x0:] = background
    Image.fromarray(a.astype(np.uint8), "RGB").save(png)
    prov.append(("gfx/menu/back_start.png", "gfx/menu/back_start.png",
                 f'baked "Version 2.213" painted out (rows {top}-{bottom} of the right strip)'))


BUBBLE_COLOURS = {1: (110, 95, 89), 2: (195, 195, 195), 3: (94, 98, 228), 4: (84, 235, 126),
                  5: (246, 224, 72), 6: (205, 82, 236), 7: (228, 90, 106), 8: (247, 143, 70)}


def render_bubble(colour, n: int, seed: int) -> Image.Image:
    """Resolution-independent glossy ice bubble in one of the original colours (the "Smooth"
    bubble style selectable in Options)."""
    import numpy as np
    rng = np.random.default_rng(seed)

    def smooth_noise(scale):
        small = rng.random((max(2, n // scale), max(2, n // scale))).astype(np.float32)
        return np.asarray(Image.fromarray((small * 255).astype(np.uint8), "L").resize((n, n), Image.BICUBIC)).astype(np.float32) / 255.0

    ys, xs = np.mgrid[0:n, 0:n].astype(np.float32)
    c = (n - 1) / 2.0
    R = n * 0.5  # fill the frame like the original art (32x32 for a 32 px bubble)
    dx = (xs - c) / R
    dy = (ys - c) / R
    d = np.sqrt(dx * dx + dy * dy)
    inside = np.clip((1.0 - d) * R, 0, 1)
    z = np.sqrt(np.clip(1 - d * d, 0, 1))
    L = np.array([-0.4, -0.65, 0.65])
    L /= np.linalg.norm(L)
    ndl = np.clip(dx * L[0] + dy * L[1] + z * L[2], 0, 1)
    base = np.array(colour, np.float32) / 255.0
    base = np.clip(base + (base - base.mean()) * 0.25, 0, 1)
    marble = 0.78 + 0.44 * (smooth_noise(10) * 0.55 + smooth_noise(4) * 0.45)
    rgb = base[None, None, :] * np.clip((0.62 + 0.55 * ndl) * marble, 0, 1.4)[..., None]
    veins = np.clip((smooth_noise(6) - 0.62) * 4, 0, 1) * 0.55
    rgb = rgb + (1.0 - rgb) * veins[..., None]
    hl = np.exp(-(((dx + 0.35) ** 2 + (dy + 0.42) ** 2) / (2 * 0.32 ** 2)))
    rgb = rgb + (1.0 - rgb) * (hl * 0.9)[..., None]
    sp = np.exp(-(((dx + 0.28) ** 2 + (dy + 0.38) ** 2) / (2 * 0.09 ** 2)))
    rgb = rgb + (1.0 - rgb) * (sp * 0.95)[..., None]
    rim = np.clip((d - 0.7) / 0.3, 0, 1) ** 2 * np.clip((dx + dy) / 1.4, 0, 1)
    rgb = rgb + (1.0 - rgb) * (rim * 0.75)[..., None]
    ring = np.clip((d - 0.9) / 0.1, 0, 1)
    rgb = rgb * (1 - ring)[..., None] + (base * 0.18)[None, None, :] * ring[..., None]
    out = np.concatenate([np.clip(rgb, 0, 1), inside[..., None]], axis=2)
    return Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")


def import_smooth_bubbles(assets: Path, prov: list):
    dst = assets / "gfx_hd" / "balls"
    dst.mkdir(parents=True, exist_ok=True)
    for i, colour in BUBBLE_COLOURS.items():
        render_bubble(colour, 128, i).save(dst / f"bubble-{i}.smooth.png.hd", format="PNG")
        render_bubble(colour, 64, i).save(dst / f"bubble-{i}-mini.smooth.png.hd", format="PNG")
    prov.append(("(generated)", "gfx_hd/balls/bubble-N[-mini].smooth.png.hd", "procedural 4x bubbles for the Smooth style"))


def wood_board(w: int, h: int, seed: int = 7) -> Image.Image:
    """Procedural wooden board with a darker rounded border, same palette as the menu panel."""
    import numpy as np
    rng = np.random.default_rng(seed)
    dark = np.array([78.0, 40.0, 14.0])
    light = np.array([172.0, 110.0, 48.0])

    def smooth_noise(cols, rows, scale):
        small = rng.random((max(2, rows // scale), max(2, cols // scale))).astype(np.float32)
        return np.asarray(Image.fromarray((small * 255).astype(np.uint8), "L").resize((cols, rows), Image.BICUBIC)).astype(np.float32) / 255.0

    ys = np.arange(h)[:, None].astype(np.float32)
    warp = smooth_noise(w, h, 40) * 12.0 + smooth_noise(w, h, 10) * 4.0
    rings = 0.5 + 0.5 * np.sin((ys + warp) * 0.6)
    fine = smooth_noise(w, h, 2) * 0.25
    t = np.clip(rings * 0.75 + fine, 0.0, 1.0)[..., None]
    rgb = dark + (light - dark) * t
    # border: darken the outer 6 px and round the corners
    xs, ys2 = np.meshgrid(np.arange(w), np.arange(h))
    r = 12
    cx = np.clip(xs, r, w - 1 - r)
    cy = np.clip(ys2, r, h - 1 - r)
    d = np.sqrt((xs - cx) ** 2 + (ys2 - cy) ** 2)
    alpha = np.clip(r + 0.5 - d, 0, 1)
    edge = np.minimum(np.minimum(xs, w - 1 - xs), np.minimum(ys2, h - 1 - ys2))
    edge_d = np.where(d > 0, r - d, edge)
    shade = np.clip(edge_d / 6.0, 0.0, 1.0) * 0.55 + 0.45
    rgb = rgb * shade[..., None]
    out = np.concatenate([np.clip(rgb, 0, 255), alpha[..., None] * 255], axis=2).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def import_boards(assets: Path, prov: list):
    dst = assets / "gfx" / "menu"
    wood_board(329, 159, 3).save(dst / "board_result.png")
    wood_board(345, 124, 5).save(dst / "board_small.png")
    prov.append(("(generated)", "gfx/menu/board_result.png, board_small.png", "procedural wooden boards behind translated result texts"))


def import_clean_plates(share: Path, assets: Path, prov: list):
    """Text-free menu plates: the interior of txt_1pgame_off/over.png is refilled with its own
    text-free left column, keeping the border and gradient, so entries can be drawn as
    (translated) text on top."""
    for variant in ("off", "over"):
        src = share / "gfx" / "menu" / f"txt_1pgame_{variant}.png"
        im = Image.open(src).convert("RGBA")
        w, h = im.size
        px = im.load()
        for y in range(h):
            fill = px[6, y]
            for x in range(7, w - 7):
                px[x, y] = fill
        dst = assets / "gfx" / "menu" / f"plate_{variant}.png"
        im.save(dst)
        prov.append((str(src_rel(src)), f"gfx/menu/plate_{variant}.png", "text removed: interior refilled from the text-free column"))


def import_transitions(share: Path, assets: Path, prov: list):
    """Threshold masks for the screen transitions of CStuff.xs (store/bars/squares/circle/plasma).

    Each mask is a 640x480 8-bit image; a pixel of the new screen appears when
    mask/255 <= progress. Generated here so the shader stays trivial and deterministic.
    """
    import numpy as np
    W, H = 640, 480
    dst = assets / "gfx" / "transitions"
    rm_dir(dst)
    dst.mkdir(parents=True, exist_ok=True)
    ys, xs = np.mgrid[0:H, 0:W]
    masks = {}
    # double store, horizontal: line l = i*15 + v revealed at step i + v, mirrored top/bottom
    t = 15
    line = np.minimum(ys, H - 1 - ys)
    masks["store_h"] = (line // t + line % t) / float(H // 2 // t + t)
    col = np.minimum(xs, W - 1 - xs)
    masks["store_v"] = (col // t + col % t) / float(W // 2 // t + t)
    # bars: 16 vertical bars, even ones fill top-down, odd ones bottom-up, 40 steps
    bar = xs // (W // 16)
    masks["bars"] = np.where(bar % 2 == 0, ys // (H // 40), (H - 1 - ys) // (H // 40)) / 40.0
    # squares: 32 px squares filled along anti-diagonals from the top-left
    masks["squares"] = (xs // 32 + ys // 32) / float((W // 32 - 1) + (H // 32 - 1) + 1)
    # circle: distance from the centre, edges first (reverse it for centre first)
    mx = np.sqrt((W / 2) ** 2 + (H / 2) ** 2)
    masks["circle"] = np.sqrt((xs - W / 2) ** 2 + (ys - H / 2) ** 2) / mx
    # plasma ordering from the original data file, and random points
    raw = np.frombuffer((share / "data" / "plasma.raw").read_bytes(), dtype=np.uint8).reshape(H, W)
    masks["plasma"] = raw / float(raw.max() + 1)
    rng = np.random.default_rng(20260906)
    masks["noise"] = rng.random((H, W))
    for name, m in masks.items():
        img = Image.fromarray(np.clip(m * 255.0, 0, 255).astype(np.uint8), "L")
        img.save(dst / f"{name}.png")
    prov.append(("data/plasma.raw", "gfx/transitions/plasma.png", "8-bit ordering map for the plasma transition"))
    prov.append(("(generated)", "gfx/transitions/{store_h,store_v,bars,squares,circle,noise}.png", "transition threshold masks from CStuff.xs formulas"))


def main():
    global ROOT_SHARE, ROOT_ASSETS
    here = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--share", default=str(here.parent / "share"))
    ap.add_argument("--assets", default=str(here / "assets"))
    ap.add_argument("--ai", choices=("auto", "on", "off"), default="auto",
                    help="Real-ESRGAN for sprites: auto uses the binary/cache if present, on downloads it, off is Lanczos only")
    ap.add_argument("--no-godot-import", action="store_true",
                    help="do not run `godot --headless --import` afterwards (the game needs it to load the 1x textures)")
    ap.add_argument("--hd-scale", type=int, default=HD_SCALE, choices=(2, 3, 4),
                    help="factor of the AI-upscaled sprites (backgrounds stay 2x); 4 is best on 4K but ~4x the texture memory")
    args = ap.parse_args()
    ROOT_SHARE = Path(args.share).resolve()
    ROOT_ASSETS = Path(args.assets).resolve()
    if not ROOT_SHARE.is_dir():
        sys.exit(f"share dir not found: {ROOT_SHARE}")
    ROOT_ASSETS.mkdir(parents=True, exist_ok=True)
    prov, warnings = [], []
    global CLEAN_CACHE
    CLEAN_CACHE = here / ".cache" / "clean"

    import_gfx(ROOT_SHARE, ROOT_ASSETS, prov, warnings)
    prov.append(("share/gfx/**/*.png", "(applied in place)",
                 f"white matte removed from {clean_stats[1]} of {clean_stats[0]} images (antialiased silhouettes)"))
    import_transitions(ROOT_SHARE, ROOT_ASSETS, prov)
    remove_baked_version(ROOT_ASSETS, prov, warnings)
    import_clean_panels(ROOT_SHARE, ROOT_ASSETS, prov)
    import_clean_plates(ROOT_SHARE, ROOT_ASSETS, prov)
    import_boards(ROOT_ASSETS, prov)
    import_hd(ROOT_ASSETS, prov, warnings, args.ai, args.hd_scale)
    import_smooth_bubbles(ROOT_ASSETS, prov)
    import_fonts(ROOT_SHARE, ROOT_ASSETS, prov)
    import_plain(ROOT_SHARE, ROOT_ASSETS, "snd", "snd", prov, exts={".ogg"})
    import_locale(ROOT_SHARE, ROOT_ASSETS, prov, warnings)
    import_plain(ROOT_SHARE, ROOT_ASSETS, "icons", "icons", prov, rename=lambda n: n.replace("frozen-bubble-", "").replace("frozen-bubble", "icon"))
    levels_dst = ROOT_ASSETS / "levels"
    rm_dir(levels_dst)
    copy(ROOT_SHARE / "data" / "levels", levels_dst / "default-levelset.lvl", prov, "level format unchanged")
    for skipped, why in (("data/demo*.bz2", "old replay format not supported; demos will be re-recorded"),
                         ("gfx/menu/fblogo.png, fblogo-mask.png", "copied but must not be used: Frozen-Bubble logo")):
        warnings.append(f"not imported: {skipped} ({why})")

    lines = ["# Asset provenance", "",
             "Generated by `tools/import_assets.py` from the original Frozen-Bubble `share/` tree.",
             "All files are Copyright 2000-2012 The Frozen-Bubble Team, GPL-2 (see `../COPYING`, `../CREDITS.md`).",
             "Do not edit files under `assets/` by hand (except `fonts/*.ttf`); re-run the script.", "",
             "| Source (share/) | Destination (assets/) | Note |", "|---|---|---|"]
    for s, d, n in prov:
        lines.append(f"| {s} | {d} | {n} |")
    lines += ["", "## Notes", ""] + [f"- {w}" for w in warnings]
    (ROOT_ASSETS / "PROVENANCE.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    # the locale step clears assets/locale, which also holds the fork's own translations
    print("regenerating Boreal Bounce translations (tools/gen_translations.py) ...")
    subprocess.run([sys.executable, str(Path(__file__).resolve().parent / "gen_translations.py")], check=True)
    pruned = prune_sidecars(ROOT_ASSETS)
    print(f"{len(prov)} provenance entries, {len(warnings)} notes" + (f", {pruned} stale .import files removed" if pruned else ""))
    for w in warnings:
        print("  note:", w)
    if not args.no_godot_import:
        godot = os.environ.get("GODOT") or shutil.which("godot")
        if godot is None:
            print("note: godot not found on PATH; run `godot --headless --path . --import` before playing")
        else:
            print("running godot --import to refresh the texture cache ...")
            r = subprocess.run([godot, "--headless", "--path", str(here), "--import"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
            print("  done" if r.returncode == 0 else f"  godot --import exited with status {r.returncode}")


if __name__ == "__main__":
    main()
