#!/usr/bin/env python3
"""Turns the landmark PDFs into pin assets plus their traced outlines.

Each PDF embeds one 1254x1254 RGB medallion render and a matching grayscale
SMask. The SMask is the artwork's alpha, which means the outline does not have
to be recovered from a background the way Minted's ArtworkAnalyzer does -- the
hard half of that problem is already solved in the source art.

Outputs, for every PDF found:
  assets/pins/<name>.webp                  512px, alpha kept, under 100 KB
  lib/src/pins/pin_outlines.g.dart         traced silhouettes as SVG path data

Run:  python3 tool/build_pins.py [source-dir]
"""

import base64
import glob
import math
import os
import re
import sys
import zlib

from PIL import Image, ImageFilter

OUT_IMAGES = 'assets/pins'
OUT_DART = 'lib/src/pins/pin_outlines.g.dart'

SIZE = 512
MAX_BYTES = 100 * 1024

# The alpha level at which the artwork is considered solid. The renders have
# soft antialiased edges, so a mid threshold sits on the true silhouette.
ALPHA_THRESHOLD = 128

# How far the traced polyline may stray from the pixel boundary, in pixels.
# Bigger means fewer points on the rim.
SIMPLIFY_TOLERANCE = 1.1


# --- PDF extraction ------------------------------------------------------

def _ascii85(data):
    return base64.a85decode(data.split(b'~>')[0], adobe=False)


def extract_images(pdf_path):
    """Pulls every image XObject out of a PDF as (width, height, space, bytes)."""
    data = open(pdf_path, 'rb').read()
    found = []
    pattern = rb'<<([^<>]|<<[^>]*>>)*?/Subtype\s*/Image.*?>>\s*stream\r?\n'
    for match in re.finditer(pattern, data, re.S):
        header = match.group(0)
        start = match.end()
        end = data.index(b'endstream', start)
        width = int(re.search(rb'/Width\s+(\d+)', header).group(1))
        height = int(re.search(rb'/Height\s+(\d+)', header).group(1))
        space = re.search(rb'/ColorSpace\s*/(\w+)', header).group(1).decode()
        found.append((width, height,
                      space, zlib.decompress(_ascii85(data[start:end]))))
    return found


def artwork_from_pdf(pdf_path):
    """The medallion render as RGBA, squared up with the art centred."""
    colour = mask = None
    for width, height, space, pixels in extract_images(pdf_path):
        if space == 'DeviceRGB':
            colour = Image.frombytes('RGB', (width, height), pixels)
        elif space == 'DeviceGray':
            mask = Image.frombytes('L', (width, height), pixels)
    if colour is None:
        return None
    if mask is not None:
        colour.putalpha(mask)
    else:
        colour = colour.convert('RGBA')

    # Trim to the art, then pad back to a square so the pin keeps its aspect
    # ratio. Texture coordinates follow the pin, not its bounding box, so the
    # square frame here is the same frame the UVs are built from.
    box = colour.getchannel('A').getbbox()
    art = colour.crop(box)
    side = max(art.size)
    square = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    square.paste(art, ((side - art.width) // 2, (side - art.height) // 2))
    return square.resize((SIZE, SIZE), Image.LANCZOS)


def save_under_budget(image, path):
    """Writes WebP, stepping quality down until it fits the size budget.

    PNG cannot hold this much gradient detail in 100 KB, and a quantised
    palette bands the enamel badly. Lossy WebP keeps the alpha channel.
    """
    for quality in (92, 88, 84, 80, 74, 68, 62):
        image.save(path, 'WEBP', quality=quality, method=6)
        if os.path.getsize(path) <= MAX_BYTES:
            return quality, os.path.getsize(path)
    return quality, os.path.getsize(path)


# --- outline tracing -----------------------------------------------------

def solid_mask(alpha):
    """A filled binary mask: True where the coin body is.

    Background is found by flooding in from the border, so enclosed
    transparent gaps inside the art stay solid. A coin is one solid blank;
    interior holes would be windows through the metal.
    """
    width, height = alpha.size
    pixels = alpha.load()
    solid = [[pixels[x, y] >= ALPHA_THRESHOLD for x in range(width)]
             for y in range(height)]

    outside = [[False] * width for _ in range(height)]
    stack = []
    for x in range(width):
        stack.append((x, 0))
        stack.append((x, height - 1))
    for y in range(height):
        stack.append((0, y))
        stack.append((width - 1, y))

    while stack:
        x, y = stack.pop()
        if x < 0 or y < 0 or x >= width or y >= height:
            continue
        if outside[y][x] or solid[y][x]:
            continue
        outside[y][x] = True
        stack.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))

    return [[not outside[y][x] for x in range(width)] for y in range(height)]


def despeckle(alpha):
    """Opens the mask enough to drop hair-thin spires, and no more.

    Minted's rule: a shape that fails to tessellate renders as nothing at all,
    and thin spires are what break it -- but over-smoothing eats real art, so
    the radius backs off until the loss is acceptable.
    """
    base = alpha.point(lambda v: 255 if v >= ALPHA_THRESHOLD else 0)
    original_area = sum(base.point(lambda v: 1 if v else 0)
                        .getdata())

    for size in (7, 5, 3):
        opened = base.filter(ImageFilter.MinFilter(size)) \
                     .filter(ImageFilter.MaxFilter(size))
        area = sum(opened.point(lambda v: 1 if v else 0).getdata())
        if original_area == 0:
            break
        if (original_area - area) / original_area <= 0.02:
            return opened, size
    return base, 0


def trace_boundary(solid):
    """Moore-neighbourhood trace of the outer boundary, clockwise in image
    space (y down)."""
    height = len(solid)
    width = len(solid[0])

    start = None
    for y in range(height):
        for x in range(width):
            if solid[y][x]:
                start = (x, y)
                break
        if start:
            break
    if start is None:
        return []

    # 8-neighbourhood, clockwise from east.
    steps = ((1, 0), (1, 1), (0, 1), (-1, 1),
             (-1, 0), (-1, -1), (0, -1), (1, -1))

    def is_solid(x, y):
        return 0 <= x < width and 0 <= y < height and solid[y][x]

    contour = [start]
    current = start
    direction = 0
    for _ in range(width * height * 8):
        found = False
        # Start looking just right of where we came from.
        for offset in range(8):
            index = (direction + 6 + offset) % 8
            dx, dy = steps[index]
            candidate = (current[0] + dx, current[1] + dy)
            if is_solid(*candidate):
                current = candidate
                direction = index
                found = True
                break
        if not found:
            break
        if current == start and len(contour) > 2:
            break
        contour.append(current)
    return contour


def simplify(points, tolerance):
    """Douglas-Peucker, iterative so a long rim does not blow the stack."""
    if len(points) < 3:
        return points

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]

    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        ax, ay = points[first]
        bx, by = points[last]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)

        worst = 0.0
        index = first
        for i in range(first + 1, last):
            px, py = points[i]
            if length == 0:
                distance = math.hypot(px - ax, py - ay)
            else:
                distance = abs(dy * px - dx * py + bx * ay - by * ax) / length
            if distance > worst:
                worst = distance
                index = i

        if worst > tolerance:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))

    return [p for p, k in zip(points, keep) if k]


def outline_path_data(image):
    """Traces the artwork's silhouette as SVG path data in a 0..1 square.

    Normalised by the *image frame*, not the outline's bounding box, so the
    path and the texture share one coordinate space and the art cannot drift
    inside the coin.
    """
    alpha = image.getchannel('A')
    cleaned, radius = despeckle(alpha)
    contour = trace_boundary(solid_mask(cleaned))
    if len(contour) < 3:
        return None, 0, radius

    simplified = simplify(contour, SIMPLIFY_TOLERANCE)
    if len(simplified) < 3:
        return None, 0, radius

    width = image.size[0]
    parts = []
    for i, (x, y) in enumerate(simplified):
        command = 'M' if i == 0 else 'L'
        parts.append(f'{command}{x / width:.4f} {y / width:.4f}')
    return ' '.join(parts) + ' Z', len(simplified), radius


# --- code generation -----------------------------------------------------

def title_of(slug):
    small = {'of', 'the', 'and'}
    words = []
    for index, word in enumerate(slug.split('-')):
        words.append(word if index and word in small else word.capitalize())
    return ' '.join(words)


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/Downloads')
    os.makedirs(OUT_IMAGES, exist_ok=True)
    os.makedirs(os.path.dirname(OUT_DART), exist_ok=True)

    entries = []
    for pdf in sorted(glob.glob(os.path.join(source, '*.pdf'))):
        slug = os.path.splitext(os.path.basename(pdf))[0]
        art = artwork_from_pdf(pdf)
        if art is None:
            print(f'  skip {slug}: no image found')
            continue

        image_path = os.path.join(OUT_IMAGES, f'{slug}.webp')
        quality, size = save_under_budget(art, image_path)
        path_data, points, radius = outline_path_data(art)
        if path_data is None:
            print(f'  skip {slug}: could not trace an outline')
            continue

        entries.append((slug, title_of(slug), path_data))
        print(f'  {slug:38s} {size // 1024:3d} KB q{quality}  '
              f'{points:3d} pts  open r{radius}')

    lines = [
        '// GENERATED by tool/build_pins.py -- do not edit by hand.',
        '//',
        "// Each pin's silhouette, traced from its artwork's alpha channel and",
        '// normalised into the same 0..1 square the texture is sampled from, so',
        '// the outline and the image cannot drift apart.',
        '',
        'class PinOutline {',
        '  const PinOutline({',
        '    required this.slug,',
        '    required this.title,',
        '    required this.pathData,',
        '  });',
        '',
        '  final String slug;',
        '  final String title;',
        '',
        '  /// Silhouette in a 0..1 y-down square.',
        '  final String pathData;',
        '',
        "  String get assetPath => 'assets/pins/$slug.webp';",
        '}',
        '',
        'const List<PinOutline> kPinOutlines = <PinOutline>[',
    ]
    for slug, title, path_data in entries:
        lines.append('  PinOutline(')
        lines.append(f"    slug: '{slug}',")
        lines.append(f"    title: '{title}',")
        lines.append("    pathData:")
        # Wrap the path data so the generated file stays readable.
        chunk = ''
        for token in path_data.split(' '):
            if len(chunk) + len(token) > 68:
                lines.append(f"        '{chunk.strip()} '")
                chunk = ''
            chunk += token + ' '
        lines.append(f"        '{chunk.strip()}',")
        lines.append('  ),')
    lines.append('];')

    with open(OUT_DART, 'w') as handle:
        handle.write('\n'.join(lines) + '\n')

    print(f'\n{len(entries)} pins -> {OUT_IMAGES}/ and {OUT_DART}')


if __name__ == '__main__':
    main()
