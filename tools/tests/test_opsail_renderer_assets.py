#!/usr/bin/env python3
import hashlib
import json
import pathlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
ASSET_ROOT = REPO_ROOT / "Vendor/Opsail/Renderer"


class OpsailRendererAssetTests(unittest.TestCase):
    def test_manifest_matches_the_exact_local_only_bundle(self):
        manifest = json.loads((ASSET_ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["assetVersion"], "1.0.1")
        self.assertEqual(
            [record["name"] for record in manifest["files"]],
            [
                "opsail-refit-codex-dom-adapter.js",
                "opsail-refit-codex-renderer-control.js",
                "opsail-refit-codex-usage-model.js",
                "opsail-refit-codex-usage-runtime.js",
            ],
        )
        for record in manifest["files"]:
            data = (ASSET_ROOT / record["name"]).read_bytes()
            self.assertEqual(len(data), record["bytes"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), record["sha256"])
            source = data.decode("utf-8")
            for forbidden in (
                "fetch(",
                "XMLHttpRequest",
                "WebSocket(",
                "eval(",
                "new Function",
                "/v1/",
                "responses.create",
                "chat.completions",
            ):
                self.assertNotIn(forbidden, source)

    def test_bilingual_hierarchy_and_compact_dates(self):
        model = ASSET_ROOT / "opsail-refit-codex-usage-model.js"
        script = f"""
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync({json.dumps(str(model))}, "utf8");
const createModel = vm.runInNewContext(
  source + "; createOpsailRefitCodexUsageModel",
  {{ Intl, Date, Math, Number, Object, String, Map }}
);
const localeBundle = {{
  defaultLocale: "en-US",
  supportedLocales: ["en-US", "zh-CN"],
  locales: {{
    "en-US": {{
      locale: "en-US",
      summaryItem: "{{label}} · {{remaining}}% left",
      windowResetCountdown: "Resets in {{countdown}}",
      windowReset: "{{dateTime}}",
      resetCreditCountdownUnits: {{ day: "d", hour: "h", minute: "m", separator: " " }},
      windowLabels: {{ weekly: "Weekly quota", generic: "Usage" }},
      summaryWindowLabels: {{ weekly: "Weekly", generic: "Usage" }}
    }},
    "zh-CN": {{
      locale: "zh-CN",
      summaryItem: "{{label}} · 剩余 {{remaining}}%",
      windowResetCountdown: "{{countdown}}后重置",
      windowReset: "{{dateTime}}",
      resetCreditCountdownUnits: {{ day: "天", hour: "小时", minute: "分钟", separator: " " }},
      windowLabels: {{ weekly: "每周额度", generic: "额度" }},
      summaryWindowLabels: {{ weekly: "本周", generic: "额度" }}
    }}
  }}
}};
const model = createModel(localeBundle);
const now = new Date(2026, 6, 30, 12, 0, 0).getTime();
const reset = new Date(2026, 6, 31, 18, 5, 49).getTime() / 1000;
for (const locale of ["en-US", "zh-CN"]) {{
  const copy = model.selectLocale(locale);
  const windows = model.presentWindows(
    {{ primary: {{ usedPercent: 68, windowDurationMins: 10080, resetsAt: reset }} }},
    copy,
    locale,
    now
  );
  console.log(JSON.stringify({{
    locale,
    label: windows[0].label,
    summary: model.summaryFor(windows, copy),
    dateTime: windows[0].reset.dateTime
  }}));
}}
"""
        result = subprocess.run(
            ["node", "-e", script],
            check=True,
            capture_output=True,
            text=True,
        )
        english, chinese = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(english["label"], "Weekly quota")
        self.assertEqual(english["summary"], "Weekly · 32% left")
        self.assertRegex(english["dateTime"], r"Jul 31.*18:05")
        self.assertNotIn("2026", english["dateTime"])
        self.assertNotIn(":49", english["dateTime"])
        self.assertEqual(chinese["label"], "每周额度")
        self.assertEqual(chinese["summary"], "本周 · 剩余 32%")
        self.assertRegex(chinese["dateTime"], r"7月31日.*18:05")
        self.assertNotIn("2026", chinese["dateTime"])
        self.assertNotIn(":49", chinese["dateTime"])

    def test_visible_metadata_is_compact_but_accessibility_stays_complete(self):
        runtime = (
            ASSET_ROOT / "opsail-refit-codex-usage-runtime.js"
        ).read_text(encoding="utf-8")
        visible_meta = runtime.split(
            "setText(row.meta, [", 1
        )[1].split("].filter(Boolean)", 1)[0]
        self.assertNotIn("copy.used", visible_meta)
        self.assertIn('join(" · ")', runtime)
        self.assertNotIn(
            'createElement("p", "opsail-refit-codex-time-format-note")',
            runtime,
        )
        self.assertIn("copy.ariaMeta", runtime)
        self.assertIn("windowValue.reset.full", runtime)


if __name__ == "__main__":
    unittest.main()
