# Codex widget idle-background evidence

`idle-summary-window.png` is a direct 2x capture of the native 84 x 25 point
overlay window from the isolated real-data QA build at source commit
`bb4f816ee5977935203320cf97dd4147cf7de951`. The window keeps its transparent
AppKit panel; the SwiftUI summary now supplies only a 1.8% semantic-primary
fill and a 5.5% semantic-primary 0.5-point border while idle. No account name,
credential, or conversation content is present.

`idle-background-comparison.png` places the earlier fully transparent idle
capture on the left and the exact new overlay capture over the same Codex-like
`#fcfcfc` host surface on the right. The quota text, 84 x 25 point geometry,
placement, and orange warning color are unchanged; only the requested resting
surface and hairline outline differ.

`expanded-details-window.png` is the direct 2x capture of the unchanged native
hover detail window from the same exact build. It confirms the semantic window
background, title, quota row, progress bar, and reset-credit section remain
intact after the idle-summary-only adjustment.

The build used the copied real-data shadow database and copied QA defaults with
no credentials. `qa/check-artifacts.sh` passed, and the source database
fingerprint remained unchanged before cleanup.

SHA-256:

- `idle-summary-window.png`: `45992a17dad996cef1b7a1b609efc0227007c1c4f205217401cdda97cf334046`
- `idle-background-comparison.png`: `7681dd252068ff250b23f18122a98d392f434e0bb8e88e8233563ef3989a3c23`
- `expanded-details-window.png`: `b9a6b8930559e8d416424457a8cbc43cc23eb438122e1e21ac0599ba35c7025d`
