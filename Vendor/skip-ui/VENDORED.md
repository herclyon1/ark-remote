# Vendored skip-ui

This directory is skip-ui **1.61.0** (https://github.com/skiptools/skip-ui, revision
`0787680f42258100db5e3fe2d7b4b358641a8dc8`) without its `.git`, with two patches. The root `Package.swift` depends on it
by path; a root path dependency with the identity `skip-ui` stands in for the remote one skip-fuse-ui asks for, so
`Package.resolved` has no skip-ui pin. Both patches are Android-only (Compose code under `#if SKIP`); the iOS build uses
SwiftUI itself and is unchanged.

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

## Patch 2: one state saver under `.id` (`Sources/SkipUI/SkipUI/View/AdditionalViewModifiers.swift`, decided 10-14)

`TagModifier.IdStateSaver` returns the parent's `ComposeStateSaver` on every pass (the line is marked `ark-remote
patch`). Upstream (1.61.0 `AdditionalViewModifiers.swift:1757-1769`; main `fa339f6`, 10-14, `:1758-1770`, the same code)
returns a fresh `ComposeStateSaver()` for the one pass in which the `.id` value changed and the parent's on every later
pass.

1. Measured defect: the 0.5.1 Android full replay aborted once (SIGABRT) at `farm.done` with `Could not cast value of
   type 'Swift.Optional<Any>' to 'SkipBridge.SwiftEquatable'` in `skip.ui.View.onChange`. skip-fuse-ui's `onChange`
   wraps the value in a `SwiftEquatable` that is never null, so the null came from skip-ui's `onChange`
   (`AdditionalViewModifiers.swift:906-930`): its `rememberSaveable` restored null.
2. Cause: `ComposeStateSaver` keeps non-primitive values (a `SwiftEquatable`) in a map of its own instance and saves
   only a `Key`; restoring that `Key` through another instance gives null. With the fresh saver, a lazy row composed
   in the pass that changed the id, and dropped in the next frame before it recomposed, was saved into the fresh saver
   and restored through the parent's. StatusPage's List has `.id(reselect)`; the replay's `farm.show` taps 状态 while
   it is selected (a reselect) and then sends the state that drops the 开始刷 row, whose `StatusAsking` has an
   `onChange`; `farm.done` brings the row back. On the emulator (2-3 frames a second) the state can land in the frame
   after the tap, so the crash came once and did not come on re-runs.
3. Test: `Android/app/src/test/kotlin/ark/remote/IdStateSaverTest.kt` (`gradle :app:testDebugUnitTest`, Robolectric).
   On the upstream code `onChange` ran with `(null, [v])` and the subtree saw two savers; with the patch, no call and
   one saver. Every `rememberSaveable` with a non-primitive value under such a row lost it the same way (a probe there
   restored null), so the fix is the saver, not a null check in `onChange`.
4. Why one saver is enough: the `key(value)` that `TagModifier.Evaluate` / `Render` put around the subtree still gives
   every `rememberSaveable` in it a new key when the id changes, so nothing of the old id is restored; `Key` numbers
   come from one counter for the whole process, so the parent's map never mixes two values. Saved values of an old id
   stay in the parent's map until the process ends (they did in the fresh one too while anything held it). The patch
   also drops upstream's `rememberedId` write during composition, which cost one extra pass per id change.
5. Process death is no second path to a null restore here: `Main.kt` calls `saveableStateHolder.removeState(true)`, so
   the activity saves no Compose state to restore.

## Upgrading Skip

Copy the new skip-ui release over this directory (keep this file), re-apply the lines marked `ark-remote patch`, update
the revision above, then build Android, run `gradle :app:testDebugUnitTest` (IdStateSaverTest) and the replay's `layout`
page (`--only setup,layout`). If skip-ui gains a
working `listSectionSpacing`, drop this directory and the path dependency instead and use the modifier on both
platforms.
