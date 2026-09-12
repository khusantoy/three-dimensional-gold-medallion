# SVG → 3D gold medallion

Turns 2D vector art into a physically-lit gold solid you can spin with a finger.
This repository currently holds the two-layer subsystem plus an example page for
inspecting it.

## Running the example

Flutter GPU must be turned on explicitly — it is not the same thing as Impeller:

```sh
flutter pub get
flutter run --enable-flutter-gpu
```

The manifest keys are already committed:

| Platform | File | Key |
|---|---|---|
| iOS | `ios/Runner/Info.plist` | `FLTEnableFlutterGPU` = `true` |
| Android | `android/app/src/main/AndroidManifest.xml` | `io.flutter.embedding.android.EnableFlutterGPU` = `true` |

Without `--enable-flutter-gpu` the app builds and launches, but the 3D panel
stays blank.

## The pins

`tool/build_pins.py` turns the landmark PDFs into the app's assets:

```sh
python3 tool/build_pins.py ~/Downloads
```

For each PDF it pulls out the embedded 1254x1254 render and its alpha mask,
squares the art up, writes `assets/pins/<name>.webp` at 512px under 100 KB, and
traces the silhouette into `lib/src/pins/pin_outlines.g.dart`.

The alpha mask is why this is tractable at all. Minted's `ArtworkAnalyzer`
spends 667 lines recovering an outline from a photographic background, because
a pin's drop shadow is a desaturated halo that a naive flood fill eats. These
renders ship their own alpha, so the outline is already exact and only needs
despeckling, tracing and simplifying.

Each pin is then extruded into three separately-materialed faces, the way
SceneKit's `SCNShape` hands out material slots: the artwork on the front, gold
on the rim and the reverse.

## What the old example page showed

A three-stage view of the same pipeline, switchable at the top:

1. **Contours** — what the SVG parser produced, after curves are flattened to
   line segments. If the outline is wrong here, the fault is in parsing.
2. **Triangles** — the real ear-clipped cap, read back out of the built mesh,
   with holes cut out. If the outline was right and this is wrong, the fault is
   in the triangulator.
3. **3D solid** — extruded, gold, lit by an environment map. Drag to orbit,
   pinch or scroll to zoom.

Ten built-in shapes exercise the cases that break naive triangulators (concave
notches, reflex corners, counters that must become holes, an unclosed outline),
and any SVG `d` attribute or whole `<svg>` document can be pasted in.

## How a coin is built

Minted's key structural idea, which is not obvious from the outside: **the coin
is not one extrusion of your SVG.** It is a stack of thin extruded slabs on a
struck blank, and your artwork is the raised enamel in the middle of it.

| Slab | Depth | Rise | Surface |
|---|---|---|---|
| body | 0.10 | — | gold |
| rim band, outer | 0.03 | 0.012 | gold |
| rim band, inner | 0.03 | 0.022 | gold |
| engraving backdrop | 0.03 | 0.005–0.010 | enamel + gold |
| art | 0.03 | 0.012 | enamel |
| beads | 0.03 | 0.013 | gold |

Every measurement is in coin-diameter units, and every slab's `rise` sits its
front proud of the face while its back stays buried in the body, so nothing
pokes out of the reverse. Pick `Custom` as the silhouette and your SVG becomes
the coin's own outline instead of its centre art.

## Architecture

The two layers are kept strictly apart, because the rendering backend is the
part most likely to be replaced.

**Layer A — geometry** (`lib/src/geometry/`). Pure Dart: no Flutter, no
`flutter_scene`, no GPU. Input is SVG path data, output is a plain data struct
of `Float32List`s plus an explicit success-or-failure result.

| File | Role |
|---|---|
| `contour.dart` | `Vec2`, `Contour`, `MedallionMesh`, the error types |
| `svg_flattener.dart` | SVG `d` → closed contours; also a minimal `<svg>` reader |
| `earcut.dart` | Ear-clipping triangulation with hole support |
| `extruder.dart` | Contours → caps + rim wall, normals, UVs, winding |

**Layer B — rendering** (`lib/src/render/`). Consumes Layer A's struct, uploads
it with `MeshGeometry.fromArrays`, attaches a metal material, and exposes one
widget. It does not know that SVG exists.

The boundary is `MedallionMesh`. If `flutter_scene` is ever swapped out, Layer A
is untouched.

## Notes from building it

- **`ExtrudeGeometry` is not an extruder.** Despite the name, it sweeps a
  profile polygon along a path, and its end caps come from `addFanCap`, whose
  own doc says "End caps assume a convex profile." Coin silhouettes are almost
  never convex, so the triangulation is ours. That is what `earcut.dart` is.
- **Winding is silent.** `flutter_scene` front faces wind counter-clockwise in
  model space; clockwise geometry is invisible from outside and shows only its
  inside, with no error. The cap and wall winding is asserted by unit test
  rather than eyeballed.
- **Gold needs something to reflect.** At metalness 1.0 there is no diffuse term
  at all, so with no environment the coin renders as a flat dark disc.
  `EnvironmentMap.studio()` is a procedural studio map generated at runtime and
  is `flutter_scene`'s zero-config default, so no HDRI has to be sourced or
  shipped. The example page also offers the 2:1 panorama bundled inside the
  `flutter_scene` package, for a busier reflection.
- **Failures are never silent.** A shape that fails to tessellate renders as
  nothing at all, so the geometry layer returns a named error — empty path,
  unparseable path, degenerate contours, or triangulation failure — and the
  example page shows it instead of a blank panel.

## Tests

```sh
flutter test
```

Layer A is covered without a widget binding or a GPU: the `d` grammar
(relative commands, shorthands, elliptical arcs, unclosed subpaths), a concave
arrowhead whose triangle areas must sum exactly to the polygon area, a ring
with a hole, triangle winding on both caps, nesting depth for the letter B's
two counters, and every error path.

Rendering is not covered. It cannot be asserted from here — it needs a
screenshot from a real device.

## Third-party

- `flutter_scene` (MIT) — rendering, materials, image-based lighting.
- `path_parsing` (BSD-3-Clause) — the SVG `d` grammar, including arc→cubic
  conversion.
- Ported from [Minted](https://github.com/haplollc/Minted) by Haplo LLC (MIT).
  Its license is vendored at `third_party/minted/LICENSE`. The coin
  composition, proportions, decorative geometry, materials, camera and light
  rig, and the momentum-flick interaction all follow it.
- The triangulator follows the structure of [mapbox/earcut](https://github.com/mapbox/earcut)
  (ISC). Its license is vendored at `third_party/earcut/LICENSE`.

All sample artwork in `lib/src/example/sample_shapes.dart` was authored for this
repository.
