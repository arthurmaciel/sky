#!/usr/bin/env bash
# Input battery for 07-todo-cli. $1 = path to the built binary.
# Runs a deterministic command sequence; masks volatile ids/timestamps so two
# runs (or two backends) are byte-comparable. Adapt the flags/env to the
# example's real CLI (read examples/07-todo-cli/src/Main.sky).
set -u
BIN="$1"
tmp=$(mktemp -d)
out() { TODO_DB="$tmp/todos.db" timeout 20 "$BIN" "$@" </dev/null 2>&1; }
{
  out add "buy milk"
  out add "write spec"
  out list
  out done 1
  out list
  out remove 2
  out list
  out clear
} | sed -E 's/\b[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+/<ts>/g; s/\bid=[0-9]+/id=<n>/g'
rm -rf "$tmp"
