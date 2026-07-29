#!/usr/bin/env python3
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class OpsailHelperPackagingTests(unittest.TestCase):
    def source(self, relative_path: str) -> str:
        return (REPO_ROOT / relative_path).read_text(encoding="utf-8")

    def test_fetcher_pins_release_and_both_macos_checksums(self):
        fetcher = self.source("tools/fetch-opsail-helper.sh")

        self.assertIn('OPSAIL_VERSION="0.2.0"', fetcher)
        self.assertIn(
            "https://github.com/lencx/opsail/releases/download/v${OPSAIL_VERSION}",
            fetcher,
        )
        self.assertNotIn("/releases/latest/", fetcher)
        self.assertNotIn("/archive/refs/heads/", fetcher)
        self.assertIn(
            "32e3c00cd5548807df6d1264c2ed902c275c8550b76313f96802a964e83ac94a",
            fetcher,
        )
        self.assertIn(
            "9db8807ffa8110e3c690ce08c2e6bb46a7d44767f1d677ca9eb45ac5e191a999",
            fetcher,
        )
        self.assertIn("shasum -a 256", fetcher)
        self.assertIn('"opsail ${OPSAIL_VERSION}"', fetcher)

    def test_developer_id_embeds_helper_but_app_store_does_not(self):
        build = self.source("build.sh")

        helper_block = build.split(
            'if [[ "${QM_DISTRIBUTION}" == "developer-id" ]]; then', 1
        )[1].split('echo "==> Verifying and embedding PrivacyInfo.xcprivacy"', 1)[0]
        self.assertIn('OPSAIL_HELPER_SOURCE="$("${OPSAIL_HELPER_FETCHER}")"', helper_block)
        self.assertIn('"${CONTENTS}/Helpers/opsail"', helper_block)
        self.assertNotIn('"app-store"', helper_block)

    def test_notarization_signs_nested_helper_before_the_app(self):
        notarize = self.source("tools/notarize.sh")

        helper_sign = notarize.index('sign_code "${OPSAIL_HELPER}"')
        app_sign = notarize.index('echo "==> codesign ${APP_BUNDLE}"')
        self.assertLess(helper_sign, app_sign)

    def test_vendor_provenance_and_license_are_recorded(self):
        provenance = self.source("Vendor/Opsail/README.md")
        notices = self.source("THIRD_PARTY_NOTICES.md")

        self.assertIn("05b8a844b1c27110ab9c66e0de4cdc5bc003a34c", provenance)
        self.assertIn("4580d275d9910e68be2ebf6a524ce2ea6f98a5a9", provenance)
        self.assertIn("Apache-2.0", provenance)
        self.assertIn("official `opsail` v0.2.0", notices)
        self.assertTrue((REPO_ROOT / "LICENSES/Opsail-Apache-2.0.txt").is_file())

    def test_custom_cdp_and_renderer_sources_are_removed(self):
        removed_sources = [
            "QuotaMonitor/App/CodexSidebarQuotaController.swift",
            "QuotaMonitor/Core/CodexSidebar/CodexSidebarQuotaCDPResponse.swift",
            "QuotaMonitor/Core/CodexSidebar/CodexSidebarQuotaEndpointValidator.swift",
            "QuotaMonitor/Core/CodexSidebar/CodexSidebarQuotaRenderer.swift",
            "QuotaMonitor/Core/CodexSidebar/CodexSidebarQuotaTarget.swift",
        ]

        for relative_path in removed_sources:
            self.assertFalse((REPO_ROOT / relative_path).exists(), relative_path)


if __name__ == "__main__":
    unittest.main()
