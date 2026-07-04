# covey Liquid Glass (Slice 18) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopt Liquid Glass on covey's floating layer (which-key, help, toast, usage chip) and buttons (prompt answers `.glass`, sheet primaries `.glassProminent`).

**Architecture:** Pure styling sweep — no logic, no protocol, no new types. Floating overlays swap `.background(<material>, in: <shape>)` for `.glassEffect(_:in:)`; prompt-answer buttons swap `.bordered` for `.glass`; each sheet's primary action button gains `.buttonStyle(.glassProminent)` (Cancel buttons untouched; destructive roles keep their red via `role:`). Spec: `docs/superpowers/specs/2026-07-04-covey-liquid-glass-design.md`.

**Tech Stack:** SwiftUI on macOS 26 (`glassEffect`, `GlassButtonStyle`, `GlassProminentButtonStyle` — all 26.0+, project already targets macOS 26).

## Global Constraints

- All code, comments, and string literals in English (docs/ excepted).
- Git write operations are performed BY THE USER; the task ends with the exact command.
- Glass ONLY on the floating layer and listed buttons: terminal pane, session list rows, text fields, sheet interiors, and the form's suggestion lists stay untouched.
- No `GlassEffectContainer`, no `glassEffectID`, no tints — out of scope per spec §4.
- Verification gate: `swift build` + `swift test` green + the visual smoke below (styling is not unit-testable).

---

### Task 1: glass sweep — overlays, prompt buttons, sheet primaries

**Files:**
- Modify: `Sources/covey/Views/WhichKeyView.swift:59`
- Modify: `Sources/covey/Views/HelpOverlay.swift:53`
- Modify: `Sources/covey/Views/ContentView.swift:153` (toastBar)
- Modify: `Sources/covey/Views/UsageChip.swift:40`
- Modify: `Sources/covey/Views/SessionListView.swift:144` (prompt buttons)
- Modify: `Sources/covey/Views/Sheets.swift:37,69,110,153,221,292,319,346` (primaries)
- Modify: `Sources/covey/Views/NewSessionSheet.swift:135` (Create)

**Interfaces:**
- Consumes: SwiftUI macOS 26 `glassEffect(_:in:)`, `.buttonStyle(.glass)`, `.buttonStyle(.glassProminent)`.
- Produces: nothing new — visual-only.

- [ ] **Step 1: Overlays** — four one-line swaps:

`WhichKeyView.swift:59`:
```swift
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
```
(replaces `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))`)

`HelpOverlay.swift:53`:
```swift
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
```
(replaces `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))`)

`ContentView.swift:153` (inside `toastBar`):
```swift
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
```
(replaces `.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))`)

`UsageChip.swift:40`:
```swift
            .glassEffect()
```
(replaces `.background(.quaternary, in: Capsule())` — the default glass shape IS a capsule)

- [ ] **Step 2: Prompt-answer buttons** — `SessionListView.swift:144`, in the prompt `ForEach`:

```swift
                        .buttonStyle(.glass)
```
(replaces `.buttonStyle(.bordered)`; `.controlSize(.mini)` and `.lineLimit(1)` stay)

- [ ] **Step 3: Sheet primaries** — add `.buttonStyle(.glassProminent)` to each primary action button (Cancel buttons untouched):

`Sheets.swift:37` RestartSheet:
```swift
                Button("Restart") {
                    Task {
                        if let err = await model.restart(name) { error = err }
                        else { model.modal = nil }
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
```

`Sheets.swift:69` RestartAllSheet:
```swift
                Button("Restart all") { run() }
                    .buttonStyle(.glassProminent)
                    .disabled(!confirmsRestart(confirmation))
```

`Sheets.swift:110` PromoteSheet:
```swift
                Button("Promote") { confirm() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
```

`Sheets.swift:153` DeleteBranchSheet (role keeps it red):
```swift
                Button("Delete", role: .destructive) { confirm() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
```

`Sheets.swift:221` CleanupSheet:
```swift
                Button("Delete selected") { confirm() }
                    .buttonStyle(.glassProminent)
```
(keep any modifiers already attached to that button — check the surrounding lines when editing)

`Sheets.swift:292` RenameProjectSheet:
```swift
                Button("Rename") {
                    model.setProjectName(dir: dir, name: name)
                    model.modal = nil
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
```

`Sheets.swift:319` KillSheet (role keeps it red):
```swift
                Button("Kill", role: .destructive) {
                    let rm = removeWorktree
                    Task {
                        await model.kill(name, removeWorktree: rm)
                        model.modal = nil
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
```

`Sheets.swift:346` RenameSheet:
```swift
                Button("Rename") {
                    let target = newName
                    Task {
                        await model.rename(name, to: target)
                        model.modal = nil
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty)
```

`NewSessionSheet.swift:135`:
```swift
                Button("Create") { submit() }
                    .buttonStyle(.glassProminent)
                    .disabled(dir.isEmpty || (!terminal && effectiveAgent.isEmpty))
```

- [ ] **Step 4: Build + full suite**

Run: `swift build && swift test`
Expected: build clean, all tests PASS (no logic touched — any failure means a stray edit).

- [ ] **Step 5: Visual smoke** — restart the app (daemon restart NOT needed — GUI-only):

```bash
swift run covey
```

1. `space` → which-key floats as glass over live terminal output.
2. `?` → help overlay is glass.
3. Trigger a toast (e.g. a failing git op) → glass capsule at the bottom.
4. Select a claude session → usage chip is a glass capsule.
5. A session with a pending prompt → `1 …`/`2 …` buttons are glass and clickable.
6. ⌘W (Kill sheet): "Kill" is red prominent glass, "Cancel" plain; ⌘N: "Create" is accent prominent glass.
7. System Settings → Accessibility → Display → Reduce Transparency ON → everything stays readable (system handles the fallback).

- [ ] **Step 6: Hand the commit to the user**

```bash
git add Sources/covey/Views/WhichKeyView.swift Sources/covey/Views/HelpOverlay.swift Sources/covey/Views/ContentView.swift Sources/covey/Views/UsageChip.swift Sources/covey/Views/SessionListView.swift Sources/covey/Views/Sheets.swift Sources/covey/Views/NewSessionSheet.swift
git commit -m "feat(covey): liquid glass on floating overlays and action buttons"
```
