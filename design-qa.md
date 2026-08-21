# M · IMAGO design QA

- Source visual truth:
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-7366caab-8e39-4899-a0d9-54fb75c36fa1.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-1eebe8e6-d4ce-4bc2-a5e3-6e6e60a9541a.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-c850723d-84bb-44c7-9e62-669d8ad6d6b6.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-827762a1-7143-4b15-8bfa-f2f9ebfd871d.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-30cad6a4-5d7d-4483-a6a8-668532526b45.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-d40cc74d-fb24-4a52-ae98-62bc464265fa.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-07cb271b-88c0-4ca9-b6e2-e9ce2cfeeecf.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-29d67bc5-3879-40a0-b0a3-392b2eaa9672.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-2b5c1fee-b9f4-4d7f-8230-287071def6c2.png`
  - `/var/folders/yg/gk6n3fd96sj6bq7j_c0s91th0000gn/T/codex-clipboard-a7bbed45-ab83-4dd5-8e1f-d6be6a1010fa.png`
- Implementation screenshots:
  - `QA/free-capture-style-menu.jpeg`
  - `QA/implementation-general-pingfang-storage.png`
  - `QA/implementation-recording-without-storage-card.png`
  - `QA/implementation-reel-compact-left.png`
  - `QA/implementation-reel-position-final.png`
  - `QA/implementation-reel-shifted.png`
  - `QA/implementation-screenshot.png`
  - `QA/implementation-recording.png`
  - `QA/implementation-system.png`
  - `QA/implementation-general.png`
- Viewport: fixed 520 × 840 content window, macOS light appearance.
- State: screenshot, recording, system, and general categories at rest; application information collapsed; free-capture window selection confirmed; shape style menu expanded.
- Full-view evidence: all four implementation screenshots above.
- Focused comparison evidence: `QA/status-board-comparison.png` places the status-board reference and implementation together at matching scale.
  - `QA/storage-button-font-comparison.png` compares the common storage card and its updated path action.
  - `QA/status-reel-position-comparison.png` compares the requested reel position with the updated implementation.
  - `QA/status-reel-position-final-comparison.png` verifies the final 8pt left adjustment while retaining the 7pt upward adjustment.
  - `QA/status-reel-compact-left-comparison.png` verifies the final compact scale and farther-left positioning.
  - `QA/free-capture-toolbar-comparison.png` compares the provided confirm/cancel alignment reference with the implemented icon-only toolbar and expanded shape style panel.

## Findings

No actionable P0, P1, or P2 mismatch remains for the requested changes.

- Typography: labels, details, monospaced status labels, and control text retain FormaUI typography and hierarchy.
- Typography update: FormaUI body and label text now use PingFang SC throughout M · IMAGO. Numeric reels, elapsed timers, dimensions, code, and machine-value readouts deliberately retain monospaced fonts where their function depends on fixed-width digits.
- Spacing and layout rhythm: system switch rows retain their medium reference height; screenshot, recording, shortcut, and information rows are compact without shrinking the reference switches. The four category controls use the shorter medium button height.
- Status board: the second row is top-aligned across both columns; the floating-thumbnail label is level with the image-format label; the reel has additional separation from its label.
- Numeric reel positioning: the reel and suffix are shifted upward by 7pt while the status dot, label, row height, and board dimensions remain unchanged.
- Numeric reel horizontal positioning: the same group is shifted left by 8pt without moving its label or changing the grid geometry.
- Numeric reel compactness: the reel group is rendered at 88% scale and positioned 14pt left, retaining the 7pt upward alignment.
- Colors and tokens: existing FormaUI surface, ink, accent, line, and selection-dot tokens are unchanged.
- Images and assets: the real application icon remains in use; no placeholder or generated asset was introduced.
- Copy and content: existing M · IMAGO labels and settings content are preserved.
- Interaction/state: sound set 1 is selected by default when no preference exists; application information is collapsed by default; dropdowns use the medium FormaUI control size.
- Storage state: the general page is the only persistent storage-location editor. It displays “更换存储路径” when a path exists and “选择存储路径” when none exists. The recording settings page no longer repeats the storage card.
- Free-capture toolbar: the FormaButton empty-title path now renders only the icon, so cancel, confirm, annotation, text, and pin glyphs are centered. The four shape tools expose a FormaUI floating secondary panel with thin/medium/thick rails and seven color swatches without clipping.
- Free-capture toolbar follow-up: selection resize handles are removed from hit testing while a drawing tool, style panel, or text editor is active. Clicking an active tool again deactivates it; a shape tool keeps its style panel open while drawing. The style panel is aligned to the selected tool and prefers the selection's outside edge before falling back inside.
- Free-capture selection: all four edges and four corners retain resize hit targets, including when the top or left edge touches the display boundary.
- Capture behavior: selecting a window immediately activates the owning application and raises the exact AX window using window number, frame, and title matching. The overlay uses a non-activating panel so it no longer reverses the target application's frontmost state. Accessibility authorization is now included in System permissions.
- Window image output: ScreenCaptureKit uses the target display's source scale, enables scale-to-fit and aspect preservation, and no longer leaves the source window in the top-left of an oversized black canvas.
- New tools: text annotations use white PingFang SC text on a rounded translucent black background in both preview and final bitmap. Pin creates a movable, resizable, closeable all-spaces panel whose content size and resize aspect are locked to the screenshot.

## Patches made

- Restored settings switches to the medium FormaUI size and their original reference-row padding.
- Aligned status-board grid rows at the top and increased reel-label spacing.
- Reduced category buttons from large to medium height while preserving small labels/icons.
- Increased the locked main-window height from 780 to 840.
- Kept the earlier compact card, medium dropdown, default sound-set, and application-info disclosure changes.
- Shifted only the numeric reel group upward by 7pt for the floating-thumbnail status item.
- Shifted the numeric reel group left by 8pt after visual review.
- Reduced the numeric reel group to 88% and increased its total left offset to 14pt.
- Switched the shared FormaUI body and label fonts to PingFang SC while preserving functional monospaced readouts.
- Removed the duplicate recording-page storage card and made the general storage button title state-aware.
- Fixed icon-only layout in the shared FormaUI button instead of applying per-screen offsets.
- Added reusable FormaUI floating-card and color-swatch picker components for the annotation secondary panel.
- Added per-annotation color and thickness data shared by live preview and final image rendering.
- Added text annotation entry and final PingFang SC bitmap rendering.
- Added exact-window AX raise behavior and a pinned screenshot controller.
- Clamped resize edge and corner hit targets inside the overlay bounds so top and left resizing remain interactive.
- Made the capture overlay non-activating and moved exact-window raise to the moment a window selection is confirmed.
- Added title matching and app frontmost state to the AX raise fallback chain.
- Corrected independent-window pixel dimensions and scaling so copied and pinned images contain only the target window at the expected aspect ratio.
- Removed resize hit targets while toolbar editing controls are active and moved capture controls above all selection gestures.
- Kept shape style panels open during drawing, added click-again deactivation, and aligned the panel to the active tool with outside-first placement.
- Added a rounded black backing plate to live and rendered text annotations.
- Locked pinned panel content sizing and resizing to the source image aspect ratio.
- Added Accessibility to the application's permission checklist because exact cross-app window raising requires it.
- Fixed capture-toolbar sessions terminating or appearing frozen after an annotation click. The capture lifecycle now disables automatic termination and rejects AppKit termination requests while the borderless overlay is active, then restores normal termination after confirm/cancel.
- Removed synchronous window-frame mutations from FormaUI's representable update/layout callbacks and skipped identical frame applications, preventing the `_NSDetectedLayoutRecursion` stack observed in AppKit.
- Hardened FormaUI tooltip fitting and Shape geometry against zero/negative fitting sizes. Capture-overlay icon buttons intentionally suppress tooltip/sound side effects while the full-screen interaction surface is active.
- Split the screenshot toolbar and annotation style card into fixed-size sibling views, retained resize handles without rebuilding their gesture graph, and disabled their hit testing while annotation tools are active.
- Runtime verification: entered the real 2560 × 1440 overlay, selected a 1437 × 945 target, and switched rectangle, ellipse, line, arrow, and text tools. The process remained live and responsive; subsequent logs contained no new toolbar-time layout recursion, invalid geometry, or sound-center stall.

## Follow-up polish

- P3: none required for this pass.

final result: passed

## Editable screenshot annotations

- Screenshot toolbar tools use clear SF Symbols; the text tool uses the insertion-cursor icon instead of the localized `格式` glyph.
- Completed rectangle, ellipse, line, arrow, and text annotations are hit-tested from topmost to bottommost and can be dragged within the selected capture area.
- Hovered or selected annotations show a lightweight dashed selection outline and use open/closed-hand cursors while moving.
- Text annotations can be clicked again to reopen the inline editor without losing their existing content or styling.
- The FormaUI text style palette exposes independent text size, text color, and background color controls, including no background.
- Text size and background color are carried into the final capture renderer, not only the overlay preview.
- Visual interaction QA covered region selection, shape movement, thin-line movement, styled text creation, text re-editing, text movement, and pinned final-image rendering.

final result: passed
