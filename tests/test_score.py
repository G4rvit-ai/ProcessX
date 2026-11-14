import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from compare import Deviation
from score import NEVER, score_run


class ScoreTests(unittest.TestCase):
    def test_sensitive_file_read_is_scored_and_explained(self):
        score = score_run([
            Deviation("files.read_files: /etc/passwd", NEVER, 1, 0, 0),
        ])

        self.assertEqual(score.total, 8)
        self.assertEqual(score.level, "slightly unusual")
        self.assertEqual(score.findings[0].text, "read /etc/passwd (a sensitive file)")

    def test_local_socket_does_not_count_as_network(self):
        score = score_run([
            Deviation("calls.sockets.local", NEVER, 1, 0, 0),
        ])

        self.assertEqual(score.total, 0)
        self.assertEqual(score.findings, [])
        self.assertEqual(score.unscored, 1)

    def test_crash_is_scored_once_not_as_signal_and_exit(self):
        score = score_run([
            Deviation("processes.exits.killed by SIGSEGV", NEVER, 1, 0, 0),
            Deviation("processes.signals.SIGSEGV", NEVER, 1, 0, 0),
        ])

        self.assertEqual(score.total, 10)
        self.assertEqual(len(score.findings), 1)
        self.assertIn("killed by SIGSEGV", score.findings[0].text)


if __name__ == "__main__":
    unittest.main()
