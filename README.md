# ProcessX: System Call Behavior Analyzer

Runs a program on Linux, records its system calls with strace, and analyzes the pattern of calls.
An unusual pattern is a reason to look closer, not proof of malware. This is not an antivirus.

Status: Phase 1 in progress (capture a trace, parse it, print basic statistics).


```text
processx/
├── README.md
├── .gitignore
├── test_programs/   small C programs we trace (Step 4)
├── traces/          raw strace output (Steps 5-6)
└── src/            Python parser and stats (Steps 7-9)
```
