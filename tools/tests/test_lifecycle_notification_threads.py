"""Exercise production notification selectors in a Swift 6 subprocess.

A subprocess keeps a regressed executor assertion from killing the QA runner.
The callbacks are taken from AppDelegate rather than duplicated in the fixture.
"""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def callback(source, name):
    start = source.rfind('    @objc ', 0, source.index(f'func {name}(') + 1)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private ', '')


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift compiler is required')
class LifecycleNotificationThreadTests(unittest.TestCase):
    def test_notifications_from_main_and_background_queues(self):
        cases = [('AppDelegate', 'calendarDayChanged', 1),
                 ('AppDelegate', 'workspaceDidWake', 3),
                 ('CodexQuotaOverlayController', 'workspaceStateDidChange', 1),
                 ('CodexQuotaOverlayController', 'screenParametersDidChange', 1)]
        for controller, name, expected in cases:
            source = (ROOT / f'QuotaMonitor/App/{controller}.swift').read_text()
            for queue in ['main', 'global()']:
                with self.subTest(callback=name, queue=queue), tempfile.TemporaryDirectory() as directory:
                    fixture = pathlib.Path(directory) / 'main.swift'
                    binary = pathlib.Path(directory) / 'notification-test'
                    fixture.write_text('''import Foundation
import Dispatch
var calls = 0
@MainActor func record() { MainActor.assertIsolated(); calls += 1 }
@MainActor final class Updater { func checkInBackgroundIfNeeded() { record() } }
@MainActor final class AppEnvironment {
    static let shared = AppEnvironment()
    func refreshDashboardInBackgroundIfNeeded() { record() }
}
@MainActor final class Delegate: NSObject {
    var updater: Updater? = Updater()
    func requestAutomaticHistoryScan(trigger: String) { record() }
    func refreshOverlay() { record() }
''' + callback(source, name) + '''
    func start() {
        NotificationCenter.default.addObserver(self, selector: #selector(''' + name + '''),
            name: .NSCalendarDayChanged, object: nil)
    }
}
let delegate = Delegate()
delegate.start()
DispatchQueue.''' + queue + '''.async {
    NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        MainActor.assertIsolated()
        print("CALLS=\\(calls)")
        exit(calls == ''' + str(expected) + ''' ? 0 : 1)
    }
}
dispatchMain()
''')
                    compiled = subprocess.run(['swiftc', '-swift-version', '6', str(fixture), '-o', str(binary)],
                                              capture_output=True, text=True, timeout=60)
                    self.assertEqual(compiled.returncode, 0, compiled.stderr)
                    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f'CALLS={expected}', result.stdout)
