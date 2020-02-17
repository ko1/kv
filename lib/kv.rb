# frozen_string_literal: true

require "kv/version"
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
    :search, :goto, :line_mode, :wrapping,
  )
  class RenderStatus
    def to_s
      'kv'
    end
  end

  def initialize input, lines: [], search: nil, name: nil, following_mode: false, first_line: 0, line_mode: false
    @rs = RenderStatus.new
    @last_rs = nil
    @rs.y = first_line
    @rs.goto = first_line if first_line > 0
    @rs.x = 0
    @rs.last_lineno = 0
    @rs.line_mode = line_mode
    @rs.search = search
    @rs.wrapping = true

    @name = name
    @filename = @name if @name && File.exist?(@name)

    @lines = lines
    @mode = :screen

    @following_mode = following_mode
    @searching = false

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
    @meta = input.respond_to?(:meta) ? input.meta : nil

    read_async input if input
  end

  def setup_line line
    line = line.chomp
    line.instance_variable_set(:@lineno, @rs.last_lineno += 1)
    line
  end

  def read_async input
    @loading = true
    begin
      data = input.read_nonblock(4096)
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
        @file_lastpos = input.tell
      end
      input.close
      @loading = false
    end
  end

  def y_max
    @lines.size - Curses.lines + 2
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
    self.y = @rs.y
  end

  
  def standout
    Curses.standout
    yield
    Curses.standend
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

  def screen_status status, post = nil
    Curses.setpos Curses.lines-1, 0
    Curses.addstr ' '.ljust(Curses.cols)

    standout{
      Curses.setpos Curses.lines-1, 0
      Curses.addstr status
    }
    Curses.addstr post if post
    Curses.standend
  end

  LINE_ATTR = Curses::A_DIM

  def render_data
    # check update
    c_lines = Curses.lines
    c_cols  = Curses.cols

    if @rs != @last_rs
      @last_rs = @rs.dup
    else
      return
    end

    Curses.clear

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

      line = line[self.x, cols] || ''

      if !@rs.search || !(Regexp === @rs.search)
        Curses.addstr line
      else
        partition(line, @rs.search).each{|(matched, str)|
          if matched == :match
            standout{
              Curses.addstr str
            }
          else
            Curses.addstr str
          end
        }
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
    loading = @loading ? " (loading...#{@load_unlimited ? '!' : nil}#{@following_mode ? ' following' : ''}) " : ''
    x = self.x > 0 ? " x:#{self.x}" : ''
    screen_status "#{name} lines:#{self.y+1}/#{@lines.size}#{x}#{loading}#{search}#{mouse}"
  end

  def check_update
    if @loading == false
      if @filename && File.exist?(@filename) && File.mtime(@filename) > @file_mtime
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

  def render_screen
    ev = nil

    ms = @following_mode ? 100 : 500

    ctimeout ms do
      while ev == nil
        render_data
        render_status
        ev = Curses.getch
        check_update
        y_max = self.y_max

        if @rs.search && @searching
          if search_next_move
            break
          end
        end

        if @following_mode
          self.y = y_max
        end
      end

      @following_mode = false
      set_load_unlimited false
      @searching = false

      return ev
    end
  end

  def search_next_move
    last_line = @lines.size
    log (@searching..last_line)

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

  def input_str pattern, str = ''.dup, other_actions: nil
    loop{
      ev = Curses.getch

      case ev
      when 10
        return str
      when Curses::KEY_BACKSPACE
        str.chop!
      when pattern
        str << ev
      else
        if other_actions && (action = other_actions[ev])
          action.call(ev)
        else
          log "failure: #{key_name ev}"
          return nil
        end
      end
    }
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
      @following_mode = true
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
        system("vi #{@filename} +#{self.y + 1}")
        @last_rs = nil
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
    when 't'
      Curses.close_screen
      @mode = :terminal

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

    @pipe_in = nil

    if files.empty?
      if STDIN.isatty
        input = help_io
        name = 'HELP'
      else
        input = STDIN.dup
        STDIN.reopen('/dev/tty')
        name = nil
        @pipe_in = input
      end
    else
      name = files.shift
      begin
        input = open(name)
      rescue Errno::ENOENT
        case name
        when /(.+):(\d+)/
          name = $1
          @first_line = $2.to_i - 1
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
    opts.parse!(argv)
  end

  def control
    @screens.last.init_screen
    until @screens.empty?
      begin
        @screens.last.control
      rescue PopScreen
        @screens.pop
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

def partition str, search
  results = []
  loop{
    r = str.match(search){|m|
      break if m.post_match == str
      results << [:unmatch, m.pre_match]
      results << [:match, m.to_s]
      str = m.post_match
    }
    break unless r
  }
  results << [:unmatch, str]
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

  help_io = StringIO.new(help.join)
end
