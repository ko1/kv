# kv: A page viewer written by Ruby

kv is a page viewer designed for streaming data written by Ruby.

## Installation

Install it yourself as:

    $ gem install kv

# Usage

kv requires Ruby and curses gem.

## Use kv

```
# View [FILE]
$ kv [OPTIONS] [FILE]

# View results of [CMD]
$ [CMD] | kv [OPTIONS]

# View command help
$ kv

Options:
    -f                               following mode like "tail -f"
    -n, --line-number LINE           goto LINE
```

## Command on a pager

```
kv: A pager by Ruby Command list

  ?: show the help message
  q: quit

  # Moving
  k, j, [UP], [DOWN]: move cursor (y)
  h, l, [LEFT], [RIGTH]: move cursor (x)
  Ctrl-U, [PAGE UP]: page up
  Ctrl-D, [PAGE DOWN], [SPACE]: page down
  g: Goto first line
  G: Goto last line (current last line)
  \d+: Goto specified line

  # Loading
  You can load a huge file or infinite input from a pipe.
  10,000 lines ahead current line will be loaded.
  If you want to load further lines the follwoing commands will help you.

  F: Load remaining data or monitor a specified file and scroll forward.
     Pushing any keys stops loading.
     If search words (specified by commadn "/") are specified, 
     stop if the further input lines contains the search words.

  L: Toggle unlimited input mode

  # Searching
  /: search
    When you enter a search string, you can choose
    the following mode by Control key combination:
      Ctrl-R: toggle Regexp mode (Ruby's regexp)
      Ctrl-I: toggle ignore case mode
  n: search next
  p: search preview
  f: filter mode (show only matched lines)

  # Output
  s: Save screen buffer to file

  # Modes
  N: toggle line mode
  m: toggle mouse mode
  t: terminal (REPL) mode
  v: vi ("vi filename +[LINE]")
```

`G` is notable feature, `less` doesn't have. This feature jumps to "current" last line even if the pipe source command does not close output (== input for kv). You can refresh the last line by putting any command.

## Mouse mode

Not yet.

## Terminal (REPL) mode

Not yet.

# Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/ko1/kv.

# Credit

Created by Koichi Sasada at 2020.

