#!/bin/sh
# Test program with a normal mode and an odd mode ("demo.sh odd").
f=/tmp/processx_demo_sh.txt
echo "hello" > "$f"
cat "$f" > /dev/null
rm -f "$f"
if [ "$1" = "odd" ]; then
  cat /etc/passwd > /dev/null            # reads a sensitive file
  echo "x" > "$HOME/processx_odd.txt"    # writes into the home folder
  rm -f "$HOME/processx_odd.txt"
  date > /dev/null                       # starts programs it never starts normally
  hostname > /dev/null
fi
