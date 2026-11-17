import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'admin-beta.py'
if not SCRIPT.exists():
    SCRIPT = Path(__file__).resolve().parent / 'admin-beta.py'
spec = importlib.util.spec_from_file_location('admin_beta', SCRIPT)
admin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admin)


class AdminBetaTests(unittest.TestCase):
    def test_beta_increments_same_line_and_rolls_after_stable(self):
        with patch.object(admin, 'REPO', 'timmyagentic/cc-connect-next'):
            self.assertEqual(admin.next_version('0.3.7-beta.3', ['v0.3.6', 'v0.3.7-beta.3']), ('0.3.7', 4))
            self.assertEqual(admin.next_version('0.3.7', ['v0.3.7']), ('0.3.8', 1))
            self.assertEqual(admin.next_version('0.3.6-beta.2', ['v0.3.7-beta.5']), ('0.3.7', 6))

    def test_private_beta_uses_private_feed_and_never_regresses(self):
        with patch.object(admin, 'REPO', 'timmyagentic/quota-monitor'):
            self.assertEqual(admin.next_version('1.0.16', ['v1.0.15'], '1.0.16-beta.4'), ('1.0.16', 5))
            self.assertEqual(admin.next_version('1.0.15', ['v1.0.15'], '1.0.17-beta.4'), ('1.0.17', 5))

    def test_changed_head_stops_before_merge(self):
        with patch.object(admin, 'gh', return_value={'headRefOid': 'new', 'isDraft': False, 'baseRefName': 'main'}):
            with self.assertRaisesRegex(RuntimeError, 'changed'):
                admin.check_pr(5, 'old')

    def test_closed_pr_is_not_silently_skipped(self):
        with patch.object(admin, 'gh', return_value={'headRefOid': 'old', 'isDraft': False, 'baseRefName': 'main', 'state': 'CLOSED'}):
            with self.assertRaisesRegex(RuntimeError, 'no longer open'):
                admin.check_pr(5, 'old')

    def test_invalid_and_exhausted_versions_fail(self):
        with self.assertRaises(ValueError):
            admin.next_version('invalid', [])
        with self.assertRaises(ValueError):
            admin.next_version('1.0.0', [], '1.0.0-beta.8999')

    def test_promote_preserves_bilingual_notes_and_clears_unreleased(self):
        import shutil
        validator = Path(__file__).resolve().parents[1] / 'validate-release-notes.py'
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)
            (target / 'tools').mkdir()
            shutil.copy(validator, target / 'tools/validate-release-notes.py')
            for name in ('CHANGELOG.md', 'CHANGELOG.zh-Hans.md'):
                (target / name).write_text('# Changes\n\n## [Unreleased]\n\n#### Summary\n\n- Visible change.\n\n### Fixed\n\n- **Details.** Preserved text.\n\n## [1.0.0]\n\nOld notes.\n')
            try:
                os.chdir(target)
                admin.promote_notes('1.0.1')
                for name in ('CHANGELOG.md', 'CHANGELOG.zh-Hans.md'):
                    text = (target / name).read_text()
                    self.assertIn('## [Unreleased]\n\n## [1.0.1]', text)
                    self.assertIn('Preserved text.', text)
                    self.assertIn('Old notes.', text)
            finally:
                os.chdir(previous)

    def test_release_uses_exact_merge_commit_and_checks_the_tree(self):
        with patch.object(admin, 'run', return_value='tree') as command:
            admin.checkout_release_source('pinned-sha', 'tree')
            command.assert_any_call('git', 'checkout', '--detach', 'pinned-sha')
            command.assert_any_call('git', 'merge-base', '--is-ancestor', 'pinned-sha', 'origin/main')
        with patch.object(admin, 'run', return_value='concurrent-tree'):
            with self.assertRaisesRegex(RuntimeError, 'differs'):
                admin.checkout_release_source('pinned-sha', 'validated-tree')

    def test_ci_health_identifies_the_client_and_uses_read_only_endpoint(self):
        import io
        responses = [io.BytesIO(b'{"value":"test-token"}'), io.BytesIO(b'{"ok":true}')]
        with patch.dict(os.environ, {'ACTIONS_ID_TOKEN_REQUEST_URL': 'https://example.test/token?job=1', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN': 'fixture'}):
            with patch.object(admin.urllib.request, 'urlopen', side_effect=responses) as request:
                self.assertEqual(admin.ci('health'), {'ok': True})
                sent = request.call_args_list[1].args[0]
                self.assertEqual(sent.full_url, admin.ADMIN + '/api/ci/health')
                self.assertEqual(sent.get_header('User-agent'), admin.USER_AGENT)

    def test_behind_pr_is_updated_with_an_expected_head_and_rechecked(self):
        responses = [{'headRefOid': 'original', 'mergeStateStatus': 'BEHIND'},
                     {'message': 'Updating'}, {'headRefOid': 'updated'}]
        with patch.object(admin, 'gh', side_effect=responses) as github:
            with patch.object(admin, 'run', return_value='updated') as command:
                with patch.object(admin, 'progress'), patch.object(admin, 'wait_checks') as checks:
                    self.assertEqual(admin.refresh_pr_head({'number': 7, 'sha': 'original'}), 'updated')
                    self.assertIn('expected_head_sha=original', github.call_args_list[1].args)
                    command.assert_any_call('git', 'merge-base', '--is-ancestor', 'original', 'updated')
                    checks.assert_called_once_with(7, 'updated')

    def test_branch_update_cannot_change_the_previously_tested_content(self):
        with patch.object(admin, 'run', return_value='changed'):
            with self.assertRaisesRegex(RuntimeError, 'changed the validated'):
                admin.verify_remaining_tree([{'number': 7, 'sha': 'original', 'merge_sha': 'updated'}], 'tested')


if __name__ == '__main__':
    unittest.main()
