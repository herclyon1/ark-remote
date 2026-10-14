# Vendored skip-ui

This directory is skip-ui **1.61.0** (https://github.com/skiptools/skip-ui, revision
`0787680f42258100db5e3fe2d7b4b358641a8dc8`) without its `.git`, with one patch. The root `Package.swift` depends on it
by path; a root path dependency with the identity `skip-ui` stands in for the remote one skip-fuse-ui asks for, so
`Package.resolved` has no skip-ui pin. The patch is Android-only (Compose code under `#if SKIP`); the iOS build uses
SwiftUI's own List and is unchanged.

## Why (decided 10-14)

1. Measured defect: on Android, two grouped-list sections with no header between them stood 33.5dp apart (88px at
   420dpi, ark37 emulator, 10-14), against 16dp (42px) between the groups of Android's own Settings app on the same
   emulator - twice as loose.
2. skip-ui offers no setting for it: `listSectionSpacing` is `@available(*, unavailable)` in 1.61.0
   (`Containers/List.swift:1585-1593`, a no-op; skip-fuse-ui stubs it too), and the gap is List's own chrome - the
   previous section's 8dp footer (corner mask), a gap item of the private `verticalInset = 16` (`List.swift:603`) and
   the next section's 8dp header (corner mask) (`List.swift:453-465, 1300-1310, 1370-1373`). No header or footer view
   in the App can shrink them. Upstream main still has the same code (checked 10-14).
3. SwiftPM cannot override part of a package, and a remote fork needs an account action outside this repo, so a local
   vendored copy is the self-contained way.
4. Cost: the `List.swift` patch has to be redone on each Skip upgrade (below); no runtime cost.
5. The earlier hold (iOS first, 10-07) is over: the iOS replay passes 142 of 142.

## The patch (`Sources/SkipUI/SkipUI/Containers/List.swift`, every changed line marked `ark-remote patch`)

- `sectionHeader:` - `bareHeader` = a section with no header that is not the first; its gap item uses
  `bareSectionGap` (2dp) instead of `verticalInset`, and its header is rendered `bare`.
- `RenderSectionHeader(bare:)` - a bare header is a `bareHeaderHeight` (1dp) box holding only the top corners
  (a zero-height lazy item was not drawn, which squared the corners off).
- `RenderRoundedCorners(collapsed:)` - corners `requiredHeight` inside that shorter box, moved down to start at the
  section's first row.
- `RenderFooter(inset:)` - the gap height as a parameter, default `verticalInset`.
- Constants `bareSectionGap`, `bareHeaderHeight`; import `requiredHeight`.

Effect: on Android every headerless section after the first sits about 12dp below the one above (measured 33px =
12.6dp at 420dpi on the ark37 emulator, 10-14; 32px on 10-07), the size of iOS 27's `.compact` section spacing (36px at
3x). Sections with a header, and the first section, are as upstream. The replay step `layout.gap.status`
(`scripts/replay/steps.py`) measures it and fails outside 11-13dp.

## Upgrading Skip

Copy the new skip-ui release over this directory (keep this file), re-apply the lines marked `ark-remote patch`, update
the revision above, then build Android and run the replay's `layout` page (`--only setup,layout`). If skip-ui gains a
working `listSectionSpacing`, drop this directory and the path dependency instead and use the modifier on both
platforms.
