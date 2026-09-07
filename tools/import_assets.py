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

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

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
            if key == LOGO_IMAGE:  # render the tag again instead of enlarging it
                render_logo(im.width, im.height, hd_scale).save(out, format="PNG")
                n_lanczos += 1
                continue
            patch = LOGO_PATCHES.get(key)
            ai_path = None if patch else (up.get(key) if up else None)
            if ai_path:
                big = _resample(Image.open(ai_path).convert("RGBA"), (im.width * hd_scale, im.height * hd_scale))
                n_ai += 1
            else:
                source = Image.open(patch["clean"]).convert("RGBA") if patch else im
                big = upscale_rgba(source, HD_SCALE)
                n_lanczos += 1
            if patch:  # redraw instead of enlarging what was baked at 1x
                draw_logo_patch(big, patch, big.width // im.width)
            big.save(out, format="PNG")
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


WORDMARK_LINES = ("Boreal", "Bounce")
WORDMARK_FILL = (255, 255, 255, 255)
WORDMARK_OUTLINE = (214, 20, 120, 255)  # the pink of the original painted logo
WORDMARK_SHADOW = (40, 0, 25, 110)
# The Frozen-Bubble logo is painted into these three backgrounds. Each entry is the image and
# the area to search for it; the exact rectangle comes from the logo's own pink outline.
# The third field is what to draw behind the wordmark: the 2p logo is painted on a wooden sign
# that goes away with it, so a board is rebuilt there; the other two sit on flat backgrounds.
LOGO_SPOTS = (
    ("back_one_player.png", (440, 0, 640, 170), None),
    ("backgrnd.png", (200, 370, 470, 480), "wood"),
    ("level_editor.png", (0, 350, 270, 480), None),
)
LOGO_PATCHES = {}  # gfx-relative path -> {"rect": (x0, y0, x1, y1), "clean": Path, "backing": str}


LOGO_FONT = "fonts/display/PlaypenSans-Variable.ttf"
LOGO_ART = "gfx/menu/fblogo.png"  # only read to locate and mask the copies painted into the art



DARK = (52, 8, 34, 255)
PINK = (222, 20, 120, 255)
WHITE = (255, 255, 255, 255)
LINES = ("Boreal", "Bounce")
ANGLES = (-6.0, 4.0)
WORK_SIZE = 110
OVERLAP = 0.98  # how far the second word rides up into the first  # font size the tag is composed at before being scaled to its target


def _tag_font(path, size):
    f = ImageFont.truetype(str(path), size)
    try:
        f.set_variation_by_axes([800])
    except Exception:
        pass
    return f


def _word(path, text, size, angle, seed):
    """One spray-painted word: white letters on a fat magenta body with a dark rim and runs."""
    font = _tag_font(path, size)
    rim = max(2, round(size * 0.26))
    body = max(2, round(size * 0.21))
    edge = max(1, round(size * 0.04))
    rng = np.random.default_rng(seed)
    runs = [(0.16 + 0.30 * i + 0.08 * rng.random(), size * (0.22 + 0.26 * rng.random()),
             size * (0.085 + 0.03 * rng.random())) for i in range(3)]
    drip = max(r[1] for r in runs)
    box = font.getbbox(text, stroke_width=rim)
    pad_x, pad_top = rim + 4, rim + 4
    pad_bottom = rim + int(drip) + 4
    im = Image.new("RGBA", (box[2] - box[0] + pad_x * 2, box[3] - box[1] + pad_top + pad_bottom), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    at = (pad_x - box[0], pad_top - box[1])
    base_y = at[1] + (box[3] - box[1]) - rim
    for frac, run, half in runs:  # paint runs, drawn first so the letters cover their tops
        cx = at[0] + (box[2] - box[0]) * frac
        for colour, grow in ((DARK, rim - body), (PINK, 0)):
            d.rounded_rectangle([cx - half - grow, base_y - size * 0.25, cx + half + grow, base_y + run + grow],
                                radius=half + grow, fill=colour)
    d.text(at, text, font=font, fill=DARK, stroke_width=rim, stroke_fill=DARK)
    d.text(at, text, font=font, fill=PINK, stroke_width=body, stroke_fill=PINK)
    d.text(at, text, font=font, fill=WHITE, stroke_width=edge, stroke_fill=WHITE)
    letters = Image.new("RGBA", im.size, (0, 0, 0, 0))
    ImageDraw.Draw(letters).text(at, text, font=font, fill=WHITE, stroke_width=edge, stroke_fill=WHITE)
    grad = np.linspace(1.0, 0.82, im.height, dtype=np.float32)[:, None, None]
    arr = np.asarray(letters).astype(np.float32)
    arr[..., :3] *= grad
    arr[..., 2] = np.minimum(arr[..., 2] + (1.0 - grad[..., 0]) * 55.0, 255.0)
    im.alpha_composite(Image.fromarray(arr.astype(np.uint8), "RGBA"))
    return im.rotate(angle, resample=Image.BICUBIC, expand=True)


def render_tag(path, width: int, height: int, scale: int = 1) -> Image.Image:
    """The fork's name as a spray-painted tag, fitted to width x height (times scale)."""
    target = (max(1, int(width * scale)), max(1, int(height * scale)))
    size = WORK_SIZE
    words = [_word(path, t, size, a, i + 3) for i, (t, a) in enumerate(zip(LINES, ANGLES))]
    overlap = round(size * OVERLAP)
    w = max(x.width for x in words) + round(size * 0.30)
    h = sum(x.height for x in words) - overlap
    tag = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    y = 0
    for i, im in enumerate(words):
        shift = round(size * 0.15) * (1 if i else -1)
        tag.alpha_composite(im, (max((w - im.width) // 2 + shift, 0), y))
        y += im.height - overlap
    canvas = Image.new("RGBA", (round(w * 1.04), round(h * 1.06)), (0, 0, 0, 0))
    off = ((canvas.width - w) // 2, (canvas.height - h) // 2)
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.alpha_composite(tag, (off[0] + round(size * 0.05), off[1] + round(size * 0.05)))
    sa = np.asarray(shadow).astype(np.float32)
    sa[..., :3] = 0.0
    sa[..., 3] *= 0.5
    canvas.alpha_composite(Image.fromarray(sa.astype(np.uint8), "RGBA").filter(ImageFilter.GaussianBlur(size * 0.05)))
    canvas.alpha_composite(tag, off)
    # overspray: a soft magenta cloud plus speckles, so the tag sits on paint, not on the art
    cloud = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    cloud.alpha_composite(tag, off)
    ca = np.asarray(cloud)[..., 3].astype(np.uint8)
    blur = np.asarray(Image.fromarray(ca, "L").filter(ImageFilter.GaussianBlur(size * 0.22))).astype(np.float32)
    spray = np.zeros((canvas.height, canvas.width, 4), np.float32)
    spray[..., 0], spray[..., 1], spray[..., 2] = PINK[0], PINK[1], PINK[2]
    spray[..., 3] = np.clip(blur * 2.6, 0, 255) * 0.85
    out = Image.fromarray(spray.astype(np.uint8), "RGBA")
    rng = np.random.default_rng(9)
    speck = ImageDraw.Draw(out)
    ys, xs = np.nonzero(ca > 40)
    if len(xs):
        for _ in range(110):
            i = int(rng.integers(0, len(xs)))
            ang = rng.random() * 6.283
            dist = size * (0.10 + 0.5 * rng.random())
            x, y2 = int(xs[i] + np.cos(ang) * dist), int(ys[i] + np.sin(ang) * dist)
            r = max(1, int(size * 0.011 * (0.5 + rng.random())))
            if 0 <= x < canvas.width and 0 <= y2 < canvas.height and ca[y2, x] < 40:
                speck.ellipse([x - r, y2 - r, x + r, y2 + r], fill=(PINK[0], PINK[1], PINK[2], int(110 + 90 * rng.random())))
    out.alpha_composite(canvas)
    ratio = min(target[0] / out.width, target[1] / out.height)
    scaled = out.resize((max(1, round(out.width * ratio)), max(1, round(out.height * ratio))), Image.LANCZOS)
    final = Image.new("RGBA", target, (0, 0, 0, 0))
    final.alpha_composite(scaled, ((target[0] - scaled.width) // 2, (target[1] - scaled.height) // 2))
    return final

def render_logo(width: int, height: int, scale: int = 1) -> Image.Image:
    font = ROOT_ASSETS / LOGO_FONT
    if not font.exists():
        return Image.new("RGBA", (max(1, int(width * scale)), max(1, int(height * scale))), (0, 0, 0, 0))
    return render_tag(font, width, height, scale)


def _inpaint(a, mask):
    """Fill the masked pixels by diffusing the surrounding colours inwards, then relax the
    result so the fill front does not show. Good enough under artwork that is drawn on top."""
    import numpy as np
    h, w, _ = a.shape
    out = a.astype(np.float32).copy()
    out[mask] = 0.0
    known = (~mask).astype(np.float32)
    while known.min() == 0.0:
        pad_a = np.pad(out, ((1, 1), (1, 1), (0, 0)))
        pad_k = np.pad(known, 1)
        acc = np.zeros_like(out)
        cnt = np.zeros((h, w), np.float32)
        for dy in range(3):
            for dx in range(3):
                if dy == 1 and dx == 1:
                    continue
                acc += pad_a[dy:dy + h, dx:dx + w] * pad_k[dy:dy + h, dx:dx + w, None]
                cnt += pad_k[dy:dy + h, dx:dx + w]
        new = (cnt > 0) & (known == 0)
        if not new.any():
            break
        out[new] = acc[new] / cnt[new][:, None]
        known[new] = 1.0
    for _ in range(40):
        pad_a = np.pad(out, ((1, 1), (1, 1), (0, 0)), mode="edge")
        blur = sum(pad_a[dy:dy + h, dx:dx + w] for dy in range(3) for dx in range(3)) / 9.0
        out[mask] = blur[mask]
    return out


def draw_logo_patch(image: Image.Image, patch: dict, factor: int) -> None:
    """Draw the replacement tag over one logo spot."""
    x0, y0, x1, y1 = patch["rect"]
    image.alpha_composite(render_logo(x1 - x0, y1 - y0, factor), (x0 * factor, y0 * factor))


def _pink_bbox(a, region):
    """Bounding box of the logo's magenta outline inside a search region."""
    x0, y0, x1, y1 = region
    sub = a[y0:y1, x0:x1]
    red, green, blue = sub[..., 0], sub[..., 1], sub[..., 2]
    pink = (red > 140) & (green < 115) & (blue > 110) & ((red - green) > 55)
    if pink.sum() < 200:
        return None
    ys, xs = np.where(pink)
    return int(xs.min()) + x0, int(ys.min()) + y0, int(xs.max()) + x0, int(ys.max()) + y0


def _row_fill(a, mask):
    """Fill a masked area by interpolating across each gap along its own row. The frosted
    panels are banded horizontally, so this keeps the banding, where a diffused fill leaves a
    pale blob and a row median borrows colour from the neighbouring panel."""
    out = a.copy()
    ys = np.flatnonzero(mask.any(axis=1))
    for y in ys:
        row = out[y]
        flags = mask[y].astype(np.int8)
        edges = np.flatnonzero(np.diff(np.concatenate(([0], flags, [0]))))
        for x0, x1 in zip(edges[::2], edges[1::2]):
            left = row[x0 - 1] if x0 > 0 else None
            right = row[x1] if x1 < len(row) else None
            if left is None and right is None:
                continue
            if left is None:
                left = right
            if right is None:
                right = left
            t = np.linspace(0.0, 1.0, x1 - x0 + 2, dtype=np.float32)[1:-1][:, None]
            row[x0:x1] = left * (1.0 - t) + right * t
    blur = np.asarray(Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGB")
                      .filter(ImageFilter.GaussianBlur(1.0))).astype(np.float32)
    out[mask] = blur[mask]
    return out


def _wood_fill(a, mask):
    """Fill a masked area with procedural wood grain toned to the wood around it."""
    ys, xs = np.where(mask)
    y0, y1, x0, x1 = int(ys.min()), int(ys.max()) + 1, int(xs.min()), int(xs.max()) + 1
    h, w = y1 - y0, x1 - x0
    grain = np.asarray(wood_board(w + 60, h + 60, seed=11).convert("RGB")).astype(np.float32)[30:30 + h, 30:30 + w]
    ring = _dilate(mask, 5) & ~mask
    ring[:y0, :] = False
    ring[y1:, :] = False
    ring[:, :x0] = False
    ring[:, x1:] = False
    # tone the grain to the wood around the hole only: the ring also touches snow and sky
    wood_like = ring & (a[..., 0] > a[..., 2] + 15) & (a[..., 0] > 50)
    sample = a[wood_like] if wood_like.sum() > 30 else (a[ring] if ring.any() else None)
    if sample is not None:
        flat = grain.reshape(-1, 3)
        mean = flat.mean(axis=0)
        grain = mean + (grain - mean) * 0.55  # the original plaque's grain is softer
        grain *= np.clip(np.median(sample, axis=0) / np.maximum(mean, 1e-3), 0.2, 3.0)
    out = a.copy()
    region_mask = mask[y0:y1, x0:x1]
    out[y0:y1, x0:x1][region_mask] = np.clip(grain[region_mask], 0, 255)
    return out


LOGO_IMAGE = "gen/logo.png"  # the title on the menu, rendered instead of drawn by hand
LOGO_IMAGE_SIZE = (190, 119)  # the footprint the original logo occupied on the menu


def import_icon_sizes(assets: Path, prov: list, ai: str = "auto"):
    """Desktop icons larger than the original 64x64, for the Flatpak and .desktop entry.
    Uses the AI upscaler when it is available, otherwise Lanczos."""
    src = assets / "icons" / "icon-64x64.png"
    if not src.exists():
        return
    base = Image.open(src).convert("RGBA")
    big = None
    if ai != "off":
        import upscale_ai
        up = upscale_ai.Upscaler(download=(ai == "on"))
        up.request("icons/icon-64x64.png", src)
        up.run(log=lambda *_: None)
        path = up.get("icons/icon-64x64.png")
        if path is not None:
            big = Image.open(path).convert("RGBA")  # 256x256
    if big is None:
        big = upscale_rgba(base, 4)
    for size in (128, 256):
        big.resize((size, size), Image.LANCZOS).save(assets / "icons" / f"icon-{size}x{size}.png", format="PNG")
    prov.append(("icons/icon-64x64.png", "icons/icon-128x128.png, icon-256x256.png",
                 "upscaled for desktop and Flatpak metadata"))


def import_logo(assets: Path, prov: list):
    """Write the tag as a standalone image for the menu title. `import_hd` renders its own
    copy at the high-resolution factor rather than enlarging this one."""
    out = assets / "gfx" / LOGO_IMAGE
    out.parent.mkdir(parents=True, exist_ok=True)
    render_logo(*LOGO_IMAGE_SIZE).save(out, format="PNG")
    prov.append(("(generated)", f"gfx/{LOGO_IMAGE}", "Boreal Bounce tag, the menu title"))


def remove_baked_lettering(assets: Path, prov: list, warnings: list):
    """Erase the "Network play..." lettering painted on the lobby background's bottom plank.
    The lobby draws that title as translated text instead."""
    name, region = "back_netgame.png", (440, 435, 640, 478)
    png = assets / "gfx" / name
    if not png.exists():
        warnings.append(f"{name} not found; baked lettering not removed")
        return
    a = np.asarray(Image.open(png).convert("RGB")).astype(np.float32)
    x0, y0, x1, y1 = region
    sub = a[y0:y1, x0:x1]
    light = sub.sum(axis=2) > np.percentile(sub.sum(axis=2), 92)
    ys, xs = np.where(light)
    if len(ys) < 50:
        warnings.append(f"{name}: no lettering found on the bottom plank")
        return
    pad = 3
    rect = (max(int(xs.min()) + x0 - pad, 0), max(int(ys.min()) + y0 - pad, 0),
            min(int(xs.max()) + x0 + pad + 1, a.shape[1]), min(int(ys.max()) + y0 + pad + 1, a.shape[0]))
    width = rect[2] - rect[0]
    patched = a.copy()
    if rect[0] - width >= 0:
        # the plank's grain runs along the row, so its own wood to the left, mirrored, hides
        # the lettering better than a diffused fill would
        patched[rect[1]:rect[3], rect[0]:rect[2]] = a[rect[1]:rect[3], rect[0] - width:rect[0]][:, ::-1]
        how = "replaced with the plank's own grain"
    else:
        mask = np.zeros(a.shape[:2], bool)
        mask[rect[1]:rect[3], rect[0]:rect[2]] = True
        patched = _inpaint(a, mask)
        how = "diffused away"
    Image.fromarray(np.clip(patched + 0.5, 0, 255).astype(np.uint8), "RGB").save(png, format="PNG")
    prov.append((f"share/gfx/{name}", f"gfx/{name}",
                 f'baked "Network play..." lettering at {rect} {how} (the lobby draws it as text)'))


def remove_baked_logos(share: Path, assets: Path, prov: list, warnings: list):
    """Replace the Frozen-Bubble logo painted into three backgrounds with the fork's tag.

    The painted copies are the original `menu/fblogo.png` artwork, so its own alpha channel,
    scaled to each copy, gives the exact footprint to erase: only those pixels are diffused
    away, and the surrounding scene (the frosted panel, the wooden sign, the penguins) is left
    untouched. The spray-painted "Boreal Bounce" tag is then drawn over the same footprint.
    `import_hd` redraws the tag at the higher resolution instead of enlarging this one.
    """
    logo_path = share / LOGO_ART
    if not logo_path.exists():
        warnings.append("menu/fblogo.png missing; painted-in logos not replaced")
        return
    logo = Image.open(logo_path).convert("RGBA")
    logo_box = _pink_bbox(np.asarray(logo)[..., :3].astype(int), (0, 0, logo.width, logo.height))
    if logo_box is None:
        warnings.append("menu/fblogo.png: outline not recognised; painted-in logos not replaced")
        return
    for name, region, fill in LOGO_SPOTS:
        png = assets / "gfx" / name
        if not png.exists():
            warnings.append(f"{name} not found; painted-in logo not replaced")
            continue
        a = np.asarray(Image.open(png).convert("RGB")).astype(np.float32)
        box = _pink_bbox(a.astype(int), region)
        if box is None:
            warnings.append(f"{name}: no painted logo found, left untouched")
            continue
        scale = (box[2] - box[0] + 1) / float(logo_box[2] - logo_box[0] + 1)
        lw, lh = max(1, round(logo.width * scale)), max(1, round(logo.height * scale))
        ox = box[0] - round(logo_box[0] * scale)
        oy = box[1] - round(logo_box[1] * scale)
        stamp = np.asarray(logo.resize((lw, lh), Image.LANCZOS))[..., 3] > 20
        mask = np.zeros(a.shape[:2], bool)
        sx0, sy0 = max(ox, 0), max(oy, 0)
        sx1, sy1 = min(ox + lw, a.shape[1]), min(oy + lh, a.shape[0])
        if sx1 <= sx0 or sy1 <= sy0:
            warnings.append(f"{name}: painted logo lies outside the image, left untouched")
            continue
        mask[sy0:sy1, sx0:sx1] = stamp[sy0 - oy:sy1 - oy, sx0 - ox:sx1 - ox]
        mask = _dilate(mask, 2)
        if fill == "wood":  # the 2p logo covers a wooden sign; give the sign its grain back
            filled = _wood_fill(a, mask)
        else:
            filled = _row_fill(a, mask)
        clean = Image.fromarray(np.clip(filled + 0.5, 0, 255).astype(np.uint8), "RGB")
        clean_path = CLEAN_CACHE / "logofree" / name
        clean_path.parent.mkdir(parents=True, exist_ok=True)
        clean.save(clean_path, format="PNG")
        rect = (sx0, sy0, sx1, sy1)
        LOGO_PATCHES[name] = {"rect": rect, "clean": clean_path}
        out = clean.convert("RGBA")
        draw_logo_patch(out, LOGO_PATCHES[name], 1)
        out.convert("RGB").save(png, format="PNG")
        prov.append((f"share/gfx/{name}", f"gfx/{name}",
                     f"painted-in Frozen-Bubble logo at {rect} erased with its own mask and replaced by the Boreal Bounce tag"))


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
    remove_baked_logos(ROOT_SHARE, ROOT_ASSETS, prov, warnings)
    remove_baked_lettering(ROOT_ASSETS, prov, warnings)
    import_clean_panels(ROOT_SHARE, ROOT_ASSETS, prov)
    import_clean_plates(ROOT_SHARE, ROOT_ASSETS, prov)
    import_boards(ROOT_ASSETS, prov)
    import_logo(ROOT_ASSETS, prov)
    import_hd(ROOT_ASSETS, prov, warnings, args.ai, args.hd_scale)
    import_smooth_bubbles(ROOT_ASSETS, prov)
    import_fonts(ROOT_SHARE, ROOT_ASSETS, prov)
    import_plain(ROOT_SHARE, ROOT_ASSETS, "snd", "snd", prov, exts={".ogg"})
    import_locale(ROOT_SHARE, ROOT_ASSETS, prov, warnings)
    import_plain(ROOT_SHARE, ROOT_ASSETS, "icons", "icons", prov, rename=lambda n: n.replace("frozen-bubble-", "").replace("frozen-bubble", "icon"))
    import_icon_sizes(ROOT_ASSETS, prov, args.ai)
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
