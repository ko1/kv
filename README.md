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

See [COMMAND](./COMMAND) file.

`G` is notable feature, `less` doesn't have. This feature jumps to "current" last line even if the pipe source command does not close output (== input for kv). You can refresh the last line by putting any command.

# Mouse mode

Not yet.

# Terminal (REPL) mode

Not yet.

