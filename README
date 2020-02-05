# kv: A page viewr written by Ruby

kv is a pager designed for streaming data written by Ruby.

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
  ?: show the help message
  q: quit

  k, j, [UP], [DOWN],
  [PAGE UP], [PAGE DOWN], [SPACE]: move cursor
  g: Goto first line
  G: Goto last line (current last line)
  \d+: Goto specified line

  /: search
  n: search next
  p: search preview
  
  N: toggle line mode
  m: toggle mouse mode
  t: terminal (REPL) mode
```

`G` is notable feature, `less` doesn't have. This feature jumps to "current" last line even if the pipe source command does not close output (== input for kv). You can refresh the last line by putting any command.

# Mouse mode

Not yet.

# Terminal (REPL) mode

Not yet.

