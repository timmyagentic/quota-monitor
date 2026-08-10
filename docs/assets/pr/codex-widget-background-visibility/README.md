# Codex widget background visibility evidence

`calculator-active-widget-visible.png` is a privacy-cropped 2x Computer QA
capture from the isolated real-data shadow build at source commit
`19d7e62fdf6e82483a7f64396dea2d7b9ad16b56`. Calculator is the active app,
shown by its active traffic-light controls, while the compact Quota Monitor
readout remains attached to the visible but inactive Codex account row below.
The hover detail is closed.

The matching Window Server snapshot ordered Calculator first, the Quota
Monitor overlay second, and the tracked ChatGPT window third. Moving
Calculator over the account-row slot therefore covered the widget naturally;
minimizing ChatGPT removed the overlay from the on-screen window list. The QA
boundary used a copied database and copied UserDefaults without safety
overrides and reported `source_unchanged=true`.

The crop excludes the account name, conversation content, credentials, and
unrelated windows.

SHA-256:
`41908bee75706abd9f4d469189050e25897c3a48f76e0b86e6747faf0ea32466`
