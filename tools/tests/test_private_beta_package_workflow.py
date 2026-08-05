import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
WORKFLOW_PATH = REPO_ROOT / ".github/workflows/private-beta-package.yml"


class PrivateBetaPackageWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = WORKFLOW_PATH.read_text(encoding="utf-8")

    def step(self, name: str, next_name: str | None = None) -> str:
        marker = f"      - name: {name}"
        start = self.workflow.index(marker)
        if next_name is None:
            return self.workflow[start:]
        return self.workflow[
            start:self.workflow.index(f"      - name: {next_name}", start + 1)
        ]

    def test_workflow_is_manual_and_read_only(self):
        self.assertRegex(
            self.workflow,
            r"(?m)^on:\n  workflow_dispatch:\n    inputs:\n",
        )
        self.assertNotRegex(self.workflow, r"(?m)^  (push|pull_request|schedule):")
        permissions = self.workflow[
            self.workflow.index("permissions:"):self.workflow.index("concurrency:")
        ].strip()
        self.assertEqual(permissions, "permissions:\n  contents: read")
        self.assertNotRegex(self.workflow, r"(?m)^\s+[a-z-]+: write$")

    def test_exact_source_must_already_belong_to_main(self):
        validate = self.step(
            "Validate source ownership and checkout exact commit",
            "Provision authenticated-encryption tooling",
        )
        self.assertIn("^[0-9a-fA-F]{40}$", self.workflow)
        self.assertIn("git fetch --no-tags origin +refs/heads/main", validate)
        self.assertIn("git cat-file -e", validate)
        self.assertIn("git merge-base --is-ancestor", validate)
        self.assertIn("git checkout --detach", validate)
        self.assertLess(
            self.workflow.index("Validate source ownership and checkout exact commit"),
            self.workflow.index("Build, sign, and notarize Private Beta"),
        )

    def test_workflow_provisions_and_verifies_openssl_three(self):
        provision = self.step(
            "Provision authenticated-encryption tooling",
            "Validate one-time recipient certificate",
        )
        self.assertIn("brew list --versions openssl@3", provision)
        self.assertIn("brew install openssl@3", provision)
        self.assertIn("HOMEBREW_NO_AUTO_UPDATE: 1", provision)
        self.assertIn("grep -E '^OpenSSL 3", provision)

    def test_release_secrets_are_scoped_to_signing_and_notarization(self):
        build = self.step(
            "Build, sign, and notarize Private Beta",
            "Verify exact packaged build",
        )
        self.assertIn("QM_RELEASE_CHANNEL: private-beta", build)
        self.assertIn("QM_RELEASE_SIGNING: developer-id", build)
        for secret in (
            "DEVELOPER_ID_CERTIFICATE_BASE64",
            "DEVELOPER_ID_CERTIFICATE_PASSWORD",
            "APPLE_ID",
            "APPLE_TEAM_ID",
            "APPLE_APP_SPECIFIC_PASSWORD",
        ):
            with self.subTest(secret=secret):
                self.assertIn(f"secrets.{secret}", self.workflow)
        for forbidden in (
            "SPARKLE_PRIVATE_KEY",
            "PRIVATE_BETA_ADMIN_TOKEN",
            "CLOUDFLARE_API_TOKEN",
            "wrangler",
            "gh release",
            "git push",
            "appcast.xml",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, self.workflow)

    def test_one_time_certificate_uses_authenticated_encryption(self):
        certificate = self.step(
            "Validate one-time recipient certificate",
            "Import Developer ID certificate",
        )
        encrypt = self.step(
            "Encrypt package for one-time recipient",
            "Upload encrypted package only",
        )
        self.assertIn("public_key_bits < 3072", certificate)
        self.assertIn("cms -encrypt -binary -aes-256-gcm", encrypt)
        self.assertIn("CMS AuthEnvelopedData AES-256-GCM", encrypt)
        self.assertIn("recipientCertificateSHA256", encrypt)

    def test_artifact_upload_allowlist_contains_no_plaintext_dmg(self):
        upload = self.step(
            "Upload encrypted package only",
            "Remove temporary signing material",
        )
        self.assertEqual(self.workflow.count("actions/upload-artifact@"), 1)
        self.assertIn("steps.encrypt.outputs.ciphertext", upload)
        self.assertIn("steps.encrypt.outputs.metadata", upload)
        self.assertNotIn("steps.package.outputs.dmg", upload)
        self.assertNotRegex(upload, r"(?m)^\s+dist/")
        self.assertIn("retention-days: 1", upload)
        self.assertIn("include-hidden-files: false", upload)

    def test_package_provenance_is_verified_before_encryption(self):
        verify = self.step(
            "Verify exact packaged build",
            "Encrypt package for one-time recipient",
        )
        for expected in (
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "BuildCommit",
            "codesign --verify",
            "spctl --assess",
            "xcrun stapler validate",
            "shasum -a 256",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, verify)


if __name__ == "__main__":
    unittest.main()
