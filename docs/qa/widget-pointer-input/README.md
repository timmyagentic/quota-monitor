# Widget pointer input regression

Candidate source: `45a4038`. Native screenshot uses synthetic 64% remaining quota.

## Reproduction and fix

The regression test hosts the actual SwiftUI summary inside its nonactivating `NSPanel`, obtains its native mouse target through hit testing, sends a press, and lets SwiftUI render the hold label before releasing. On the previous code, the phase unexpectedly returned to idle, the mouse target changed identity, and no details activation occurred. Calling a standalone mouse view directly did not expose this failure.

A stable outer container now keeps the native input view alive when the readout changes to hold, ready, or dragging content. Tests cover both short click and the one-second hold through drag/release. Compact, single-window and dual-window widths expose the full expected hit area.

The native input surface also owns an always-active tracking area so Codex can remain foreground while hover events reach the non-key panel. Restored hover callbacks open details, preserve them while the pointer crosses into the details panel, and close after leaving both surfaces. Click opens details; Escape and click-away still close them. Expanded content and styling are unchanged.

## Validation

- The original hosted-summary click regression failed with all three symptoms above, then passed after the stable-container correction.
- Focused pointer, dragging and overlay suites: 34 tests passed, including five parameterized click/drag/width cases.
- Final repository gate: 1,054 Swift tests in 121 suites and 191 Python tests passed.
- An unmodified Developer ID candidate with isolated preferences, synthetic quota, and external data sources disabled displayed on the current Codex host. Its aggregate diagnostics reported a matched main window and a found header (97 visited nodes, 9 candidates, 1 web area).
- The native screenshot below confirms rendering. It does not certify a physical mouse click. Computer Use returned `noWindowsAvailable` for coordinate input to the independent nonactivating panel; the programmatic hosted-view regression and accessibility activation are separate evidence. Optional user feedback was not available at this checkpoint.
- QA applications were stopped and the original beta.4 runtime was restored. No installed bundle or user quota data was changed.

![Candidate native quota badge](readout-native.jpg)
