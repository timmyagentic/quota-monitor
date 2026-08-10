# Codex widget background evidence

`semantic-background-light.png` is a deterministic 2x native SwiftUI render
of the shipping `CodexQuotaOverlayView` in light appearance. It uses a
weekly-only fixture with 55% remaining on a Codex-like light host surface so
the adaptive fill and border can be judged without account or conversation
data.

`semantic-background-dark.png` renders the same exact view and fixture in
native dark appearance, confirming that the semantic tint and border reverse
with the host foreground instead of carrying a fixed light-theme color.

`semantic-background-comparison.png` places equal-size focused crops from the
user-supplied pre-change screenshot (left) and the native implementation
render (right) in one comparison image. Only the requested background and
border treatment changed; the status dot, label, percentage, geometry, and
interaction code remain unchanged.

SHA-256:

- `semantic-background-light.png`: `54da8cc0174a40bcf2ed9e4274c208f1a5bf698a4d1ab843c58b206e079786f3`
- `semantic-background-dark.png`: `2546a3192a1a088eaf4efbe540e57c22b90a5d24632917395778ffd11e09bfcf`
- `semantic-background-comparison.png`: `a11bdfeed2801cf5026036ba669b16a14194a96fa983c9e12d72b4ee0f44b46c`
