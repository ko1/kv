# frozen_string_literal: true

require_relative "kv/version"
require "curses"
require 'stringio'
require 'optparse'
require 'open-uri'

module KV
class PushScreen < Exception
  attr_reader :screen
  def initialize screen
    @screen = screen
  end
end

class PopScreen < Exception
end

class Screen
  RenderStatus = Struct.new(
    :c_cols, :c_lines, :x, :y, :last_lineno,
    :search, :goto, :wrapping,
    :line_mode, :ts_mode, :separation_mode,
  )
  class RenderStatus
    def to_s
      'kv'
    end
  end

  def initialize input, lines: [],
                 name: nil,
                 search: nil,
                 first_line: 0,
                 following_mode: false,
                 line_mode: false,
                 separation_mode: false,
                 time_stamp: nil,
                 ext_input: nil,
                 fifo_file: nil,
                 watch: false,
                 filter_command: nil

    @rs = RenderStatus.new
    @last_rs = nil
    @rs.y = first_line
    @rs.goto = first_line if first_line > 0
    @rs.x = 0
    @rs.last_lineno = 0
    @rs.line_mode = line_mode
    @rs.search = search
    @rs.wrapping = false
    @rs.ts_mode = false
    @rs.separation_mode = separation_mode

    @name = name
    @filename = @name if @name && File.exist?(@name)
    @filter_command = @filename && filter_command

    @time_stamp = time_stamp
    @ext_input = ext_input
    @fifo_file = fifo_file

    @lines = lines
    @mode = :screen

    @watch_mode = watch

    @following = following_mode
    @apos = 0

    @mouse = false
    @search_ignore_case = false
    @search_regexp = true
    @loading = false
    @buffer_lines = 10_000
    @yq = Queue.new
    if @filename
      @load_unlimited = true
    else
      @load_unlimited = false
    end

    @prev_render = {}
    input = open_file if @filename
    @meta = input.respond_to?(:meta) ? input.meta : nil
    read_async input if input
  end

  def open_file
    input = open(@filename)
    @rs.last_lineno = 0

    if @filter_command
      io = IO.popen("#{@filter_command} #{@filename}", err: '/dev/null')
      # io.close_write
      input = io
    end
    input
  end

  def setup_line line
    line = line.chomp
    line.instance_variable_set(:@time_stamp, Time.now.strftime('%H:%M:%S')) if @time_stamp
    line.instance_variable_set(:@lineno, @rs.last_lineno += 1)
    line
  end

  def read_async input
    @loading = true
    begin
      data = input.read_nonblock(800_000)
    rescue IO::EAGAINWaitReadable, EOFError
      data = ''
    end

    last_line = nil
    data.each_line{|line|
      if line[-1] != "\n"
        last_line = line
        break
      end
      @lines << setup_line(line)
    }

    Thread.abort_on_exception = true
    @reader_thread = Thread.new do
      while line = input.gets
        if last_line
          line = last_line + line
          last_line = nil
        end

        @lines << setup_line(line)

        while !@load_unlimited && @lines.size > self.y + @buffer_lines
          @yq.pop; @yq.clear
        end
        @yq.clear
      end
    ensure
      if @filename
        @file_mtime = File.mtime(@filename)
        @file_lastpos = input.tell unless @filter_command
      elsif @fifo_file
        input = open(@fifo_file)
        log(input)
        redo
      end
      input.close
      @loading = false
    end
  end

  def y_max
    max = @lines.size - Curses.lines + 2
    max < 0 ? 0 : max
  end

  def y
    @rs.y
  end

  def y=(y)
    if y > (ym = self.y_max)
      @rs.y = ym
    else
      @rs.y = y
    end

    @rs.y = 0 if @rs.y < 0
    @yq << nil if @loading
  end

  attr_reader :x

  def x=(x)
    @rs.x = x
    @rs.x = 0 if @rs.x < 0
  end

  def x
    @rs.x
  end

  def set_load_unlimited b
    @load_unlimited = b
    @yq << true
  end

  def init_screen
    Curses.init_screen
    Curses.stdscr.keypad(true)

    if @mouse
      Curses.mousemask(Curses::BUTTON1_CLICKED | Curses::BUTTON2_CLICKED |
                       Curses::BUTTON3_CLICKED | Curses::BUTTON4_CLICKED)
    else
      Curses.mousemask(0)
    end

    if @loading && self.y_max < @rs.y
      log [:going, self.y_max, @rs.y]
      @following = :going
    end
    self.y = @rs.y
  end

  
  def standout
    cattr Curses::A_STANDOUT do
      yield
    end
  end

  def cattr attr
    Curses.attron attr
    begin
      yield
    ensure
      Curses.attroff attr
    end
  end

  def ctimeout ms
    Curses.timeout = ms
    begin
      yield
    ensure
      Curses.timeout = -1
    end
  end

  LINE_ATTR = Curses::A_DIM

  def render_data
    # check update
    c_lines = @rs.c_lines = Curses.lines
    c_cols = @rs.c_cols  = Curses.cols

    if @rs != @last_rs
      @last_rs = @rs.dup
    else
      return
    end

    Curses.clear

    if @rs.separation_mode && (lines = @lines[self.y ... (self.y + c_lines - 1)])
      @max_cols = [] unless defined? @max_cols
      lines.each.with_index{|line, ln|
        line.split("\t").each_with_index{|w, i|
          @max_cols[i] = @max_cols[i] ? [@max_cols[i], w.size].max : w.size
        }
      }
    end

    (c_lines-1).times{|i|
      lno = i + self.y
      line = @lines[lno]
      cols = c_cols

      unless line
        if lno == @lines.size
          Curses.setpos i, 0
          cattr LINE_ATTR do
            Curses.addstr '(END)'
          end
        end

        break
      end

      Curses.setpos i, 0

      if @rs.line_mode
        cattr LINE_ATTR do
          lineno = line.instance_variable_get(:@lineno)
          ln_str = '%5d |' % lineno
          if @rs.goto == lineno - 1 || (@rs.search && (@rs.search === line))
            standout do
              Curses.addstr(ln_str)
            end
          else
            Curses.addstr(ln_str)
          end
          cols -= ln_str.size
        end
      end

      if @rs.ts_mode && ts = line.instance_variable_get(:@time_stamp)
        cattr LINE_ATTR do
          ts = line.instance_variable_get(:@time_stamp)
          Curses.addstr("#{ts} |")
        end
      end

      line = line[self.x, cols] || ''

      if @rs.separation_mode
        line = line.split(/\t/).tap{|e|
          if (max = @max_cols.size) > 0
            # fill empty columns
            e[max - 1] ||= nil
          end
        }.map.with_index{|w, i|
          "%-#{@max_cols[i]}s" % w
        }.join(' | ')
      end

      if !@rs.search || !(Regexp === @rs.search) ||
         (parts = search_partition(line, @rs.search)).is_a?(String)
        Curses.addstr line
      else
        cattr Curses::A_UNDERLINE do
          parts.each{|(matched, str)|
            if matched == :match
              standout{
                Curses.addstr str
              }
            else
              Curses.addstr str
            end
          }
        end
      end
    }
  end

  def search_str
    if @rs.search
      if str = @rs.search.instance_variable_get(:@search_str)
        str
      else
        @rs.search.inspect
      end
    else
      nil
    end
  end

  def render_status
    name = @name ? "<#{@name}>" : ''
    mouse  = @mouse ? ' [MOUSE]' : ''
    search = @rs.search ? " search[#{search_str}]" : ''
    loading = @loading ? " (loading...#{@load_unlimited ? '!' : nil}#{@following ? ' following' : ''}) " : ''
    x = self.x > 0 ? " x:#{self.x}" : ''
    screen_status "#{name} lines:#{self.y+1}/#{@lines.size}#{x}#{loading}#{search}#{mouse}"
  end

  ANIMATION = ['[O     ]',
               '[o.    ]',
               '[...   ]',
               '[ ...  ]',
               '[  ... ]',
               '[   ...]',
               '[    .o]',
               '[     O]',
               '[    .o]',
               '[   ...]',
               '[  ... ]',
               '[  ... ]',
               '[ ...  ]',
               '[...   ]',
               '[o.    ]',
               ]

  def screen_status status, post = nil
    cols = Curses.cols
    line = Curses.lines-1
    Curses.setpos line, 0
    Curses.addstr ' '.ljust(cols)
    len  = status.size
    len += post.size if post

    standout{
      Curses.setpos Curses.lines-1, 0
      Curses.addstr status
    }
    Curses.addstr post if post

    if !post && len < cols - ANIMATION.first.size
      Curses.setpos line, cols - ANIMATION.first.size - 1
      @apos = (@apos + 1) % ANIMATION.size
      Curses.addstr ANIMATION[@apos]
    end
  end

  def check_update
    if @loading == false
      if @filename && File.mtime(@filename) > @file_mtime
        screen_status "#{@filename} is updated."

        if @watch_mode
          @lines = []
          input = open_file
          read_async input
        else
          input = open(@filename)

          if input.size < @file_lastpos
            screen_status "#{@filename} is truncated. Rewinded."
            pause
            @lineno = 0
          else
            input.seek @file_lastpos
          end
          read_async input
        end
      end
    end
  end

  def render_screen
    ev = nil

    ms = @following ? 100 : 500

    ctimeout ms do
      while ev == nil
        render_data
        render_status
        ev = Curses.getch
        check_update
        y_max = self.y_max

        if @following
          case @following
          when :searching
            break if search_next_move
          when :going
            if @rs.goto <= y_max
              self.y = @rs.goto
              break
            end
          when true
            # ok
          else
            raise "unknown following mode: #{@following}"
          end

          self.y = y_max
        end
      end

      @following = false
      set_load_unlimited false

      return ev
    end
  end

  def search_next_move
    last_line = @lines.size
    # log (@searching..last_line)

    (@searching...last_line).each{|i|
      if @rs.search === @lines[i]
        self.y = i
        @searching = false
        return true
      end
    }
    @searching = last_line
    return false
  end

  def search_next start
    @searching = start
    if search_next_move
      # OK. self.y is updated.
    else
      if @loading
        set_load_unlimited true
        @following = :searching
      else
        screen_status "not found: [#{self.search_str}]"
        pause
        @searching = false
      end
    end
  end

  def search_prev start
    start.downto(0){|i|
      if @rs.search === @lines[i]
        self.y = i
        return true
      end
    }
    screen_status "not found: [#{self.search_str}]"
    pause
  end

  def key_name ev
    Curses.constants.grep(/KEY/){|c|
      return c if Curses.const_get(c) == ev
    }
    ev
  end

  def input_str pattern, str = ''.dup, other_actions: {}
    update_action = other_actions[:update]

    ctimeout update_action ? 200 : -1 do
      loop do
        ev = Curses.getch

        case ev
        when 10
          return str
        when Curses::KEY_BACKSPACE
          str.chop!
        when pattern
          str << ev
        when nil # timeout
          update_action[str]
        else
          if action = other_actions[ev]
            action.call(ev)
          else
            log "failure: #{key_name ev}"
            return nil
          end
        end
      end
    end
  end

  def pause
    ev = Curses.getch
    Curses.ungetch ev if ev
  end

  def control_screen
    ev = render_screen

    case ev
    when 'q'
      raise PopScreen

    when Curses::KEY_UP, 'k'
      self.y -= 1
    when Curses::KEY_DOWN, 'j'
      self.y += 1
    when Curses::KEY_LEFT, 'h'
      self.x -= 1
    when Curses::KEY_RIGHT, 'l'
      self.x += 1
    when 'g'
      self.y = 0
      self.x = 0
    when 'G'
      self.y = self.y_max
      self.x = 0
    when ' ', Curses::KEY_NPAGE, Curses::KEY_CTRL_D
      self.y += Curses.lines-1
    when Curses::KEY_PPAGE, Curses::KEY_CTRL_U
      self.y -= Curses.lines-1

    when /[0-9]/
      screen_status "Goto:", ev
      ystr = input_str(/\d/, ev)
      if ystr && !ystr.empty?
        @rs.goto = ystr.to_i - 1
        self.y = @rs.goto
      end

    when 'F'
      @following = true
      set_load_unlimited true

    when 'L'
      set_load_unlimited !@load_unlimited

    when '/'
      search_str = ''.dup

      update_search_status = -> do
        regexp = @search_regexp ? 'regexp' : 'string'
        ignore = @search_ignore_case ? '/ignore' : ''
        screen_status "Search[#{regexp}#{ignore}]:", search_str
      end

      update_search_status[]
      input_str(/./, search_str, other_actions: {
        Curses::KEY_CTRL_I => -> ev do
          @search_ignore_case = !@search_ignore_case
          update_search_status[]
        end,
        Curses::KEY_CTRL_R => -> ev do
          @search_regexp = !@search_regexp
          update_search_status[]
        end,
      })

      if search_str && !search_str.empty?
        ic = @search_ignore_case ? [Regexp::IGNORECASE] : []
        if @search_regexp
          begin
            @rs.search = Regexp.compile(search_str, *ic)
          rescue RegexpError => e
            @rs.search = nil
            screen_status "regexp compile error: #{e.message}"
            pause
          end
        else
          @rs.search = Regexp.compile(Regexp.escape(search_str), *ic)
        end
      else
        @rs.search = nil
      end
      if @rs.search
        @rs.search.instance_variable_set(:@search_str, search_str)
        search_next self.y
      end
    when 'n'
      search_next self.y+1 if @rs.search
    when 'p'
      search_prev self.y-1 if @rs.search
    when 'f'
      if @rs.search
        filter_mode_title = "*filter mode [#{self.search_str}]*"
        if @name != filter_mode_title
          lines = @lines.grep(@rs.search)
          fscr = Screen.new nil, lines: lines, search: @rs.search, name: filter_mode_title
          raise PushScreen.new(fscr)
        end
      end

    when 's'
      screen_status "Save file:"
      file = input_str /./
      begin
        if file && !file.empty?
          if File.exist? file
            screen_status "#{file.dump} exists. Override? [y/n] "
            yn = input_str(/[yn]/)
            if yn == 'y'
              File.write(file, @lines.join("\n"))
            else
              # do nothing
              end
            else
              File.write(file, @lines.join("\n"))
            end
          end
        rescue SystemCallError
          # TODO: status line
        end

    when 'v'
      if @filename
        syste m("vi #{@filename} +#{self.y + 1}")
        @last_rs = nil
      end

    when 'P'
      begin
        if v = `gist -v` and /^gist v\d/ =~ v
          screen_status "gist-ing..."

          url = IO.popen('gist -p', 'a+'){|rw|
            @lines.each{|line| rw.puts line}
            rw.close_write
            rw.read
          }
          msg = "gist URL: #{url}"
          at_exit{
            puts msg
          }
          screen_status msg
          pause
        else
          raise v.inspect
        end
      rescue Errno::ENOENT
        screen_status 'gist command is not found'
        pause
      end

    when 'm'
      @mouse = !@mouse
      Curses.close_screen
      init_screen
    when Curses::KEY_MOUSE
      m = Curses.getmouse
      log m, "mouse ->"
      # log [m.bstate, m.x, m.y, m.z, m.eid]
      log @lines[self.y + m.y]

    when 'N'
      @rs.line_mode = !@rs.line_mode
    when 'T'
      @rs.ts_mode = !@rs.ts_mode if @time_stamp
    when 'S'
      @rs.separation_mode = !@rs.separation_mode
      @max_cols = []
    when 't'
      Curses.close_screen
      @mode = :terminal
    when 'x'
      while @ext_input && !@ext_input.closed?
        update_ext_status = -> str do
          screen_status "input for ext:", str
        end
        update_ext_status['']
        actions = {
          update: -> str do
            self.y = self.y_max
            render_data
            update_ext_status[str]
          end
        }
        str = input_str(/./, other_actions: actions)
        if str && !str.empty?
          @ext_input.puts str unless @ext_input.closed?
        else
          break
        end
      end

    when 'H'
      if @meta
        lines = @meta.map{|k, v| "#{k}: #{v}"}
        raise PushScreen.new(Screen.new nil, lines: lines, name: "Response header [#{@name}]")
      end

    when Curses::KEY_CTRL_G
      # do nothing

    when '?'
      raise PushScreen.new(Screen.new help_io)

    when nil
      # ignore

    when Curses::KEY_RESIZE
      # ignore

    else
      screen_status "unknown: #{key_name(ev)}"
      pause
    end
  end

  def control_terminal
    @rs.instance_eval('binding').irb

    @mode = :screen
    init_screen
    @last_rs = nil
  end

  def control
    case @mode
    when :screen
      control_screen
    when :terminal
      control_terminal
    else
      raise
    end
  end

  def redraw!
    @last_rs = nil
  end
end

class KV
  def initialize argv
    @opts = {
      following_mode: false,
      first_line: 0,
      line_mode: false,
    }

    files = parse_option(argv)
    name = files.shift

    @pipe_in = nil

    if @opts[:pipe] || (name && File.pipe?(name))
      @opts.delete(:pipe)
      @opts[:fifo_file] = name || '/tmp/kv_pipe'

      if name && File.pipe?(name)
        # ok
      else
        begin
          name ||= File.expand_path('~/.kv_pipe')
          unlink_name = name
          File.mkfifo(name)
          at_exit{ puts "$ rm #{unlink_name}"; File.unlink(unlink_name) }
        rescue Errno::EEXIST
          raise "#{name} already exists."
        end
      end

      puts "waiting for #{name}"
      input = @pipe_in = open(name)
      name = nil
    elsif !name
      case
      when @opts[:e]
        cmd = @opts.delete(:e)
        input = IO.popen(cmd, 'a+')
        name = nil
        @pipe_in = input
        @opts[:ext_input] = input
      when STDIN.isatty
        input = help_io
        name = 'HELP'
      else
        input = STDIN.dup
        STDIN.reopen('/dev/tty')
        name = nil
        @pipe_in = input
      end
    else
      begin
        input = open(name)
      rescue Errno::ENOENT
        case name
        when /(.+):(\d+)/
          name = $1
          @opts[:first_line] = $2.to_i - 1
          retry
        when URI.regexp
          input = URI.open(name)
        else
          STDERR.puts "#{name}: No such file or directory"
          exit 1
        end
      end
    end

    trap(:INT){
      log "SIGINT"
    }

    @screens = [Screen.new(input, name: name, **@opts)]
  end

  def parse_option argv
    opts = OptionParser.new
    opts.on('-f', 'following mode like "tail -f"'){
      @opts[:following_mode] = true
    }
    opts.on('-n', '--line-number LINE', 'goto LINE'){|n|
      @opts[:first_line] = n.to_i - 1
    }
    opts.on('-N', 'Show lines'){
      @opts[:line_mode] = true
    }
    opts.on('-T', '--time-stamp', 'Enable time stamp'){
      @opts[:time_stamp] = true
    }
    opts.on('-e CMD', 'Run CMD as a child process'){|cmd|
      @opts[:e] = cmd
    }
    opts.on('-p', '--pipe', 'Open named pipe'){
      @opts[:pipe] = true
    }
    opts.on('-s', 'Separation mode (tsv)'){
      @opts[:separation_mode] = true
    }
    opts.on('-w', 'Watch mode: Reload on file changed'){
      @opts[:watch] = true
    }
    opts.on('--filter-command=FILTER_COMMAND', 'Apply filter command'){|cmd|
      @opts[:filter_command] = cmd
    }
    opts.parse!(argv)
  end

  def control
    @screens.last.init_screen
    until @screens.empty?
      begin
        @screens.last.control
      rescue PopScreen
        @screens.pop
        @screens.last.redraw! unless @screens.empty?
      rescue PushScreen => e
        @screens.push e.screen
        @screens.last.redraw!
      end
    end
  ensure
    Curses.close_screen
    log "terminate"
  end
end
end

$debug_log = ENV['KV_DEBUG']

def log obj, prefix = ''
  if $debug_log
    File.open($debug_log, 'a'){|f|
      f.puts "#{$$} #{prefix}#{obj.inspect}"
    }
  end
end

def search_partition str, search
  results = []
  loop{
    r = str.match(search){|m|
      break if m.post_match == str
      results << [:unmatch, m.pre_match] unless m.pre_match.empty?
      results << [:match, m.to_s]
      str = m.post_match
    }
    break unless r
  }
  if results.empty?
    str
  else
    results << [:unmatch, str] unless str.empty?
    results
  end
end

def help_io
  readme = File.read(File.join(__dir__, '../README.md'))
  help = []
  readme.each_line{|line|
    if /kv: A pager by Ruby Command list/ =~ line
      help << line
    elsif /^```/ =~ line && !help.empty?
      break
    elsif !help.empty?
      help << line
    end
  }

  StringIO.new(help.join)
end
