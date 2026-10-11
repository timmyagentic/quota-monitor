import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('verify', Path(__file__).parents[1] / 'verify-cloud-pr.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class CloudEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.sha = 'a' * 40
        self.pr = {'headRefOid': self.sha, 'isDraft': False}
        self.run = {'headSha': self.sha, 'status': 'completed', 'conclusion': 'success'}
        self.jobs = [{'name': name, 'conclusion': 'success', 'labels': ['macos-15'],
                      'steps': [{'name': s, 'conclusion': 'success'} for s in steps]}
                     for name, steps in verify.REQUIRED.items()]

    def test_exact_head_real_jobs_pass(self):
        verify.validate(self.pr, self.sha, self.run, self.jobs)

    def test_stale_draft_skipped_failed_and_summary_only_rejected(self):
        cases = []
        for field, value in [('headRefOid', 'b' * 40), ('isDraft', True)]:
            pr = dict(self.pr, **{field: value})
            cases.append((pr, self.run, self.jobs))
        for field, value in [('headSha', 'b' * 40), ('conclusion', 'failure'), ('status', 'in_progress')]:
            cases.append((self.pr, dict(self.run, **{field: value}), self.jobs))
        for conclusion in ['skipped', 'failure', 'cancelled', None]:
            jobs = copy.deepcopy(self.jobs)
            jobs[0]['conclusion'] = conclusion
            cases.append((self.pr, self.run, jobs))
        jobs = copy.deepcopy(self.jobs)
        jobs[0]['steps'][0]['conclusion'] = 'skipped'
        cases.append((self.pr, self.run, jobs))
        jobs = copy.deepcopy(self.jobs)
        jobs[0]['labels'] = ['ubuntu-latest']
        cases.append((self.pr, self.run, jobs))
        cases.append((self.pr, self.run, [{'name': 'swift-test', 'conclusion': 'success'}]))
        for args in cases:
            with self.subTest(args=args), self.assertRaises(ValueError):
                verify.validate(args[0], self.sha, args[1], args[2])
