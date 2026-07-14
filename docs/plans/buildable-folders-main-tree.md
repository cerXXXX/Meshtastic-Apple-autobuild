# Plan: Convert the main `Meshtastic/` app tree to Xcode 16 buildable folders

Follow-up to issue #2026 (Option A) and PR #2085 (which converted `MeshtasticTests/`
and `Meshtastic Watch App/`). Scope here: the **main `Meshtastic/` app source tree
only**. `Widgets/` is explicitly out of scope (mixed target membership).

Branch: `plan/convert-main-tree-buildable`, off PR #2085 head (`06c8bdf1`).
Project is already `objectVersion = 70` and already uses
`PBXFileSystemSynchronizedRootGroup` for `Meshtastic/Resources/images` and
`.../PreferenceKeys`.

---

## 0. The headline risk (read this first)

When `Meshtastic/` becomes a synchronized folder, Xcode compiles **every `.swift`
physically inside it**. So any file on disk that the app target does *not* currently
compile gets pulled into the build the moment the folder is flipped.

**Ground truth (from a real build, not regex):** of 418 `.swift` files on disk under
`Meshtastic/`, the app target compiles 409; **exactly 9 are orphans** (on disk, not
compiled). This was established authoritatively by building the app
(`BUILD SUCCEEDED`) and diffing the compiler's own `Meshtastic.SwiftFileList`
against disk. (Earlier regex-based estimates of "29/46 orphans" were parser
artifacts on this heavily hand/AI-edited `project.pbxproj` — do not trust regex here;
trust the `SwiftFileList`.)

All 9 have been **auto-adjudicated and compiler-verified** (see §A). The orphan
problem is small and fully resolved: 7 wire in cleanly, 2 get deleted. This
materially de-risks the conversion.

---

## A. Pre-flight: adjudicate the 9 orphans (the gate) — DONE, compiler-verified

Method: the app was built to emit the authoritative `Meshtastic.SwiftFileList`; the 9
non-compiled on-disk files were then each **added to the app target and re-built** to
let the compiler decide. Results are empirical, not guessed.

### WIRE IN — 7 files (build succeeded with all 7 added: `BUILD SUCCEEDED`, exit 0)
Legitimate code that lost its `PBXBuildFile` in a past merge conflict; additive, no
collisions with the compiled set. Once `Meshtastic/` is synced these compile
automatically — no action needed beyond the flip, but confirm the behavior is wanted:

| File | Origin PR | What it adds |
|------|-----------|--------------|
| `Extensions/SwiftData/DeviceMetadataEntityExtension.swift` | #1752 CoreData→SwiftData | `init` + `version`/`lastDotIndex` on `DeviceMetadataEntity` |
| `Extensions/SwiftData/ExternalNotificationConfigEntityExtension.swift` | #1752 | `init` + `update(...)` |
| `Extensions/SwiftData/MQTTConfigEntityExtension.swift` | #1752 | `init` + `update(...)` |
| `Extensions/SwiftData/RangeTestConfigEntityExtension.swift` | #1752 | `init` + `update(...)` |
| `Extensions/SwiftData/SerialConfigEntityExtension.swift` | #1752 | `init` + `update(...)` |
| `Extensions/SwiftData/StoreForwardConfigEntityExtension.swift` | #1752 | `init` + `update(...)` |
| `Model/Model+Sendable.swift` | #1846 | `Sendable` conformance for 43 `@Model` entities |

Note on `Model+Sendable.swift`: it compiles clean and no entity already declares
`Sendable`, so it's purely additive — but it does change concurrency-checking surface
for 43 entities. It was clearly intended by #1846; flag it in the PR description.

### DELETE — 2 files (compiler-/collision-confirmed non-viable)
| File | Origin | Verdict |
|------|--------|---------|
| `Views/Helpers/Messages/MessageTemplate.swift` | "IOS 16 updates" (a3d20585, ancient) | **DELETE** — does not compile (`MessageTemplate.swift:42: type '()' cannot conform to 'View'`); referenced by nothing compiled. Dead code. |
| `Views/Nodes/Helpers/NodeInfo.swift` | "Add small weather widget back to node map" | **DELETE** — re-declares `struct NodeInfoItem`, which the compiled `NodeInfoItem.swift` already defines (invalid redeclaration if added). Stale copy; the live `NodeInfoItem.swift` is the one referenced by `NodeDetail.swift`. |

### Concrete pre-flight action before the flip
```bash
git rm Meshtastic/Views/Helpers/Messages/MessageTemplate.swift \
       Meshtastic/Views/Nodes/Helpers/NodeInfo.swift
# the 7 WIRE-IN files stay on disk; the sync flip compiles them automatically
```

### Gate criterion (now satisfiable)
After the two `git rm`s, every remaining `.swift` under `Meshtastic/` compiles in the
app target — verified by building with the 7 added (`BUILD SUCCEEDED`). The folder is
safe to flip. Re-run the app build once more post-deletion as the final gate check.

---

## B. `Constants.swift` cross-target resolution

`Meshtastic/Extensions/Constants.swift` compiles into **both** the Meshtastic app
(`25C49D8F…`) and **WidgetsExtension**. After `Meshtastic/` is synced, the app picks
it up implicitly; WidgetsExtension keeps its **explicit `PBXBuildFile`** pointing at
the file inside the synced folder.

- **Primary:** keep WidgetsExtension's explicit build-file reference (a target may
  explicitly compile a file that lives inside another target's synced folder).
  Verify empirically: build WidgetsExtension after conversion, confirm no duplicate
  symbols and that `Constants.swift` still compiles into it.
- **Fallback A:** move to `Widgets/Shared/Constants.swift` (outside the synced tree),
  update both targets.
- **Fallback B:** extract shared constants into a local SwiftPM target both import.

---

## C. Conversion mechanics

- **Use the Xcode UI**, mirroring #2085 (`git show 9e11c16b`, `git show 06c8bdf1`):
  right-click the `Meshtastic` group → **Convert to Folder** → review the diff.
  This produces correct exception sets; hand-editing the plist is error-prone.
- **Nested synced folders:** `Resources/images` (carries a large app-target exception
  set for the device SVGs + `image_manifest.json`) and `PreferenceKeys` are already
  synced. After converting the parent, verify those exception sets survive and the
  SVGs stay excluded from compilation. Re-add to the parent's exception set if lost.
- **Expected diff shape:** hundreds of `PBXBuildFile` + `PBXFileReference` +
  `PBXGroup` deletions; a handful of additions (one root synced group, one exception
  set, one entry in the target's `fileSystemSynchronizedGroups`).

---

## D. Non-source files

**Must be membership exceptions** (referenced by build settings, not bundled) —
same precedent as #2085's Watch App `Info.plist`/entitlements:
- `Meshtastic/Info.plist`
- `Meshtastic/Meshtastic.entitlements`
- `Meshtastic/Meshtastic-Catalyst.entitlements`

**Auto-handled as resources by sync** (verify, no exception needed): `Assets.xcassets`,
`Preview Content/Preview Assets.xcassets` (dev asset), `Meshtastic.xcdatamodeld`,
`AppIcon*.icon`, `*.lproj` variant groups, `Resources/{docs,Certificates}`,
`Resources/{DeviceHardware.json,urls.json}`, `Localizable`/`InfoPlist.strings`.

---

## E. Sequencing / PR strategy

- Land **after** #2085. Rebase this branch on it.
- **Recommended:** two coordinated PRs —
  1. `chore(project): re-wire/adjudicate orphaned files under Meshtastic/` (deletes
     stale files, wires legit ones, build stays green) — reviewable on its own merits
     since it changes what actually ships.
  2. `chore(project): convert Meshtastic/ to a buildable folder` (the flip).
  Splitting keeps the behavioral change (orphan resurrection) reviewable separately
  from the mechanical flip.
- **Blast radius:** 23 of 35 open upstream PRs touch `project.pbxproj`. Merging the
  flip forces all of them to rebase. Coordinate in #2026, pick a quiet window, and
  document that post-conversion PRs adding files to `Meshtastic/` need **zero** pbxproj
  changes (drop any `PBXFileReference`/`PBXBuildFile` additions from their diffs).

---

## F. Validation (prove equivalence)

Baseline before, repeat after:
```bash
# app-target compiled sources before conversion (count)
# build all four targets
xcodebuild -workspace Meshtastic.xcworkspace -scheme Meshtastic            -destination 'generic/platform=iOS'     build
xcodebuild -workspace Meshtastic.xcworkspace -scheme WidgetsExtension      -destination 'generic/platform=iOS'     build
xcodebuild -workspace Meshtastic.xcworkspace -scheme "Meshtastic Watch App" -destination 'generic/platform=watchOS' build
xcodebuild -workspace Meshtastic.xcworkspace -scheme MeshtasticTests       -destination 'platform=iOS Simulator,name=iPhone 15' test
```
- After: `find Meshtastic -name '*.swift' | wc -l` minus exceptions == the app's new
  compiled set. This count will be **higher than the pre-conversion compiled count by
  exactly 7** (the WIRE-IN orphans) and the two DELETEd files must be gone — that
  delta is expected, not a surprise.
- Confirm `Constants.swift` still compiles into WidgetsExtension; no duplicate symbols.
- Diff `project.pbxproj`: deletions ≫ additions; one `PBXFileSystemSynchronizedRootGroup`
  for `Meshtastic/`; exception set contains the three build-setting files.
- Full test suite: same pass/fail as baseline.

---

## G. Risks, rollback, go/no-go

**Risks:** orphan resurrection breaks build or changes behavior (HIGH — gated by A);
`Constants.swift` cross-target regression (MED — test + fallbacks); nested exception
sets lost (MED — verify); rebase pain for 23 PRs (HIGH — coordinate/timing); Xcode
emits unexpected plist (LOW — review diff).

**Rollback:** `git revert` the flip commit while local; painful once dependents rebase,
so validate thoroughly before merge.

**Go/no-go checklist:**
- [x] All 9 orphans adjudicated (compiler-verified): 7 WIRE IN, 2 DELETE
- [ ] `git rm` the 2 DELETE files (MessageTemplate.swift, NodeInfo.swift); re-build as final gate
- [ ] (no separate gate) The 7 WIRE-IN files compile automatically on flip; they're
      inert/additive (nothing compiled calls them; the app builds without them today).
      Any objection is a conversion-PR review call — exclude an unwanted file via a
      membership exception rather than blocking the work.
- [ ] Rebased on merged #2085; Xcode ≥ 16; clean tree
- [ ] Convert-to-Folder done; diff reviewed (deletions ≫ additions)
- [ ] Exception set has Info.plist + both entitlements; images/ exceptions preserved
- [ ] `Constants.swift` still builds into WidgetsExtension; no dup symbols
- [ ] All four targets build; tests match baseline
- [ ] Maintainers notified; rebase guidance posted
