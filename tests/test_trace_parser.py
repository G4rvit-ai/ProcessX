import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "src"))

from trace_parser import parse_trace


class TraceParserTests(unittest.TestCase):
    def test_parses_calls_failures_events_and_split_calls(self):
        trace_text = "\n".join([
            '100  10:00:00.000000 openat(AT_FDCWD, "/tmp/x", O_RDONLY) = -1 ENOENT (No such file) <0.000100>',
            '100  10:00:00.000100 --- SIGCHLD {si_signo=SIGCHLD} ---',
            '100  10:00:00.000200 read(3, "hello", 5 <unfinished ...>',
            '100  10:00:00.000300 <... read resumed> ) = 5 <0.000200>',
            '100  10:00:00.000500 +++ exited with 0 +++',
        ]) + "\n"
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as file:
            file.write(trace_text)
            file.flush()
            parsed = parse_trace(file.name)

        self.assertEqual(len(parsed.syscalls), 2)
        self.assertEqual(parsed.syscalls[0].error, "ENOENT")
        self.assertEqual(parsed.syscalls[1].ret, "5")
        self.assertEqual(parsed.second_halves, 1)
        self.assertEqual([event.kind for event in parsed.events], ["signal", "exit"])
        self.assertEqual(parsed.unparsed, [])


if __name__ == "__main__":
    unittest.main()
