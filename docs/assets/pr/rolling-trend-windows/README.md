# Rolling trend window QA evidence

`fixture-90d-a3a0026.jpg` was captured from the isolated fixture QA build whose
embedded `BuildCommit` was `a3a0026`.

- The fixture uses synthetic Codex and Claude records, an isolated HOME, and an
  isolated UserDefaults suite; no real credentials or user data are included.
- The 90-day range is selected because the deterministic fixture events fall
  outside the current 30-day window.
- The chart, cache-rate line, range controls, legend, statline, Activity, and
  Composition surfaces render without clipping or overlap.

The application source is unchanged by the commit that adds this evidence.
