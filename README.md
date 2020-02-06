# kv: A page viewer written by Ruby

kv is a page viewer designed for streaming data written by Ruby.

# Usage

kv requires Ruby and curses gem.

## Use kv

```
View help
$ kv

View [FILE]
$ kv [FILE]

View [CMD] output
$ [CMD] | kv
```

## Command on a pager

```
kv: A pager by Ruby Command list

  ?: show the help message
  q: quit

  # Moving
  k, j, [UP], [DOWN],
  [PAGE UP], [PAGE DOWN], [SPACE]: move cursor
  g: Goto first line
  G: Goto last line (current last line)
  \d+: Goto specified line

  # Loading
  You can load a huge file or infinite input from a pipe.
  10,000 lines ahead current line will be loaded.
  If you want to load further lines, the follwoing commands
  will help you.

  F: Load remaining data and scroll forward
  L: Load reamining data but no scroll

  Pushing any keys stops loading.

  # Searching
  /: search
    When you enter a search string, you can choose
    the following mode by Control key combination:
      Ctrl-R: toggle Regexp mode (Ruby's regexp)
      Ctrl-I: toggle ignore case mode
  n: search next
  p: search preview

  # Output
  s: Save screen buffer to file

  # Modes
  N: toggle line mode
  m: toggle mouse mode
  t: terminal (REPL) mode
```

`G` is notable feature, `less` doesn't have. This feature jumps to "current" last line even if the pipe source command does not close output (== input for kv). You can refresh the last line by putting any command.

## Mouse mode

Not yet.

## Terminal (REPL) mode

Not yet.

# Credit

Created by Koichi Sasada at 2020.

