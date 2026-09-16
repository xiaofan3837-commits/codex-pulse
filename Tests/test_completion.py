"""Check completion retention and native Codex read-state reconciliation."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class CompletionTests(unittest.TestCase):
    def test_completion_lifecycle_and_read_state(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / 'completion-tests'
            result = subprocess.run([
                'swiftc', '-module-cache-path', directory + '/cache', '-lsqlite3',
                str(ROOT / 'Source/TaskStore.swift'),
                str(ROOT / 'Source/CompletionTracker.swift'),
                str(ROOT / 'Tests/CompletionTests.swift'), '-o', str(binary)
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
