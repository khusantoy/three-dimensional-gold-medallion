# 3D gold medallion

Turns 2D vector art, or a finished pin render, into a physically-lit 3D gold
medallion you can spin with a finger. No 3D model files: every mesh is built
from paths at runtime.

A Dart port of [Minted](https://github.com/haplollc/Minted) by Haplo LLC (MIT),
which is Swift and SceneKit, onto `flutter_scene` and Flutter GPU.

## Running

```sh
flutter pub get
flutter run
```

The app opens on the Tashkent landmark collection: one pin turning in 3D, the
rest of the set below it. Drag any direction to turn it, flick to spin it,
double tap to reset.

Flutter GPU has to be enabled once per platform, and it is **not** the same
thing as Impeller. The keys are already committed, so no run flag is needed:

| Platform | File | Key |
|---|---|---|
| iOS | `ios/Runner/Info.plist` | `FLTEnableFlutterGPU` = `true` |
| Android | `android/app/src/main/AndroidManifest.xml` | `io.flutter.embedding.android.EnableFlutterGPU` = `true` |

`flutter run --enable-flutter-gpu` does the same thing for one run, and is the
fallback if the keys are ever lost. Without either, the app still launches but
the 3D panel stays blank.

## The two routes in

Minted takes artwork two ways, and so does this.

**A finished pin render** (`lib/src/pins/`, what the app shows). The image
becomes the coin's face, its outline is traced from the artwork, and the gold
painted *into* the art is detected and turned into relief. Rim and reverse stay
real metal.

**Vector art** (`lib/src/geometry/coin_assembly.dart`). An SVG path becomes the
raised centre art on a struck blank — a wax-seal scallop, an octagon, a circle
or a diamond — with rosette petals, sunburst rays or a lattice behind it, a
beaded rim, and a rolled lip. Or the SVG becomes the coin's own outline
instead. This route is library code with its own tests; it is not currently on
screen.

## Building the pins

`tool/build_pins.py` turns the landmark PDFs into the app's assets:

```sh
python3 tool/build_pins.py ~/Downloads
```

For each PDF it pulls out the embedded 1254×1254 render and its alpha mask,
squares the art up, writes `assets/pins/<slug>.webp` at 512px under 100 KB, and
traces the silhouette into `lib/src/pins/pin_outlines.g.dart`.

The alpha mask is why the artwork route is tractable at all. Minted's
`ArtworkAnalyzer` spends most of its 667 lines recovering an outline from a
photographic background, because a pin's drop shadow is a desaturated halo that
a naive flood fill eats. These renders carry their own alpha, so the outline is
already exact and only needs despeckling, tracing and simplifying.

The outline is normalised by the *image frame*, not by its own bounding box, so
the silhouette and the texture share one coordinate space. Minted's warning
applies directly: texture coordinates follow the pin, not its bounding box, or
a tall pin squeezes its artwork inward and shows flat margins down both sides.

## Why the pins look raised

Two separate things, and both are geometry or lighting rather than paint.

**The gold in the artwork becomes relief.** Warm pixels that also carry local
contrast — or are simply blown out — are read as painted metal. The warmth test
alone would also catch skin, sand and terracotta; what separates metal from
those is that it holds a highlight and a shadow within a few pixels. That mask
is blurred into a height field and differentiated into a normal map, and packed
into a metallic-roughness map so the same pixels shade as metal. Both maps are
derived at load time on a background isolate from the image already being
shipped, so they cost no extra assets.

**The rim is a real band of metal.** The artwork paints its own border, but a
painted border is flat. A copy of the outline is offset inward along each
vertex's angle bisector, and the ring between the two is extruded and stood
proud of the face. That is what catches a highlight travelling along the edge
as the pin turns.

## How a coin is built

Minted's key structural idea, which is not obvious from the outside: **a coin
is not one extrusion.** It is a stack of thin extruded slabs on a struck blank.

For the vector route:

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
pokes out of the reverse. The artwork route is thinner — pins are thin — at a
body of 0.055 with one rim band at a rise of 0.005.

## Architecture

Two layers, kept strictly apart because the rendering backend is the part most
likely to be replaced.

**Layer A — geometry** (`lib/src/geometry/`). Pure Dart: no Flutter, no
`flutter_scene`, no GPU, so it is exercised by `flutter test` alone.

| File | Role |
|---|---|
| `contour.dart` | `Vec2`, `Contour`, `MedallionMesh`, the part and surface enums, the error and result types |
| `svg_flattener.dart` | SVG `d` → closed contours, plus a minimal `<svg>` reader |
| `earcut.dart` | Ear-clipping triangulation with hole support |
| `extruder.dart` | Contours → a solid, whole or split into front, back and rim |
| `offset.dart` | Inward polygon offsetting, and the band between a ring and its inset |
| `artwork_analyzer.dart` | Gold detection → normal and metallic-roughness maps |
| `coin_design.dart` | Silhouette curves, decorative geometry, coin proportions |
| `coin_assembly.dart` | The slab stack for the vector route |

**Layer B — rendering** (`lib/src/render/`). Consumes Layer A's structs,
uploads them with `MeshGeometry.fromArrays`, attaches materials, and sets up the
camera and lights.

| File | Role |
|---|---|
| `gold_material.dart` | Palette, the four surfaces, the camera and light rig |
| `medallion_view.dart` | The vector-route coin |

**The app** (`lib/src/pins/`) is the landmark collection: `pin_view.dart` for
one pin in 3D, `pins_page.dart` for the page, `pin_outlines.g.dart` generated
by the tool.

The boundary between A and B is a plain struct of `Float32List`s plus an
explicit success-or-failure result. If `flutter_scene` is ever swapped out,
Layer A is untouched.

## Notes that cost real time

Everything here is a silent failure: it compiles, it runs, and it renders the
wrong pixels or none at all.

- **`ExtrudeGeometry` is not an extruder.** Despite the name it sweeps a profile
  polygon along a path, and its end caps come from `addFanCap`, whose own doc
  says "End caps assume a convex profile." Coin silhouettes are almost never
  convex, so the triangulation is ours. That is what `earcut.dart` is.

- **A camera looks along its node's +Z.** SceneKit's looks along −Z, so Minted's
  camera position carried over unchanged pointed *away* from the coin and
  rendered an empty frame. Aim it with `lookAtFrom` rather than translating a
  node and hoping.

- **The field of view is vertical.** A fixed camera distance frames a square
  view and crops the sides off a portrait one. The distance is computed from the
  view's aspect ratio.

- **Winding is silent.** `flutter_scene` front faces wind counter-clockwise in
  model space; clockwise geometry is invisible from outside and shows only its
  inside, with no error. The winding is asserted by unit test rather than
  eyeballed.

- **Gold needs something to reflect.** At metalness 1.0 there is no diffuse term
  at all, so with no environment a coin renders as a flat dark disc.
  `EnvironmentMap.studio()` is a procedural studio map built at runtime and is
  `flutter_scene`'s zero-config default, so no HDRI has to be sourced or shipped.

- **Texture content is not a detail.** A normal map passed as colour is
  gamma-decoded: normals flatten and skew *with distance only*, which is close
  to the worst case to diagnose from a screenshot.

- **Failures are never silent here.** A shape that fails to tessellate renders
  as nothing at all, so the geometry layer returns a named error — empty path,
  unparseable path, degenerate contours, triangulation failure — and the UI
  shows it instead of a blank panel.

## Tests

```sh
flutter test
```

135 tests, none of which need a GPU: the `d` grammar including elliptical arcs
and unclosed subpaths; a concave arrowhead whose triangle areas must sum
exactly to the polygon's; rings, counters and nesting depth; triangle winding on
both caps; the gold detector against warm paint that is *not* metal; normal maps
that must stay unit length; the glTF metallic-roughness packing; polygon
offsetting including the miter clamp; and the camera framing at every aspect
ratio.

Rendering itself is not covered and cannot be. `flutter_scene` needs Impeller,
which the test binding does not provide, so `Scene`'s constructor throws and the
whole 3D subtree is replaced by an error widget. Anything inside the panel — the
camera, the pose, the materials — can only be checked on a device.

## Known gaps

- The reverse has no orange-peel relief yet; only its roughness differs.
- Rim band width is a fixed starting value that backs off until the outline can
  carry it. Minted measures it per pin from how deep the artwork's own border
  ink runs.
- Offsetting a concave outline far enough makes the ring cross itself, and a
  self-intersecting ring has no well-defined inside. The width backs off until
  it tessellates; two of the ten pins need that.
- Engraved arc lettering is out of scope: Minted uses CoreText glyph outlines,
  and Dart has no public glyph-outline API.

## Third-party

- Ported from [Minted](https://github.com/haplollc/Minted) by Haplo LLC (MIT).
  Its license is vendored at `third_party/minted/LICENSE`. The coin composition,
  proportions, decorative geometry, materials, camera and light rig, gold
  detection, relief baking, polygon offsetting and the momentum-flick
  interaction all follow it.
- The triangulator follows the structure of
  [mapbox/earcut](https://github.com/mapbox/earcut) (ISC). Its license is
  vendored at `third_party/earcut/LICENSE`.
- [`flutter_scene`](https://pub.dev/packages/flutter_scene) (MIT) — rendering,
  materials, image-based lighting.
- [`path_parsing`](https://pub.dev/packages/path_parsing) (BSD-3-Clause) — the
  SVG `d` grammar, including arc→cubic conversion.

Test artwork in `test/fixtures/shapes.dart` was authored for this repository.
The landmark renders in `assets/pins/` are the collection's own.
