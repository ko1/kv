# frozen_string_literal: true

require "kv/version"
require "curses"
require 'stringio'
require 'optparse'

module KV
class KV_PushScreen < Exception
  attr_reader :screen
  def initialize screen
    @screen = screen
  end
end

class KV_PopScreen < Exception
end

class KV_Screen
  def initialize input, lines: [], search: nil, name: nil, following_mode: false
    @y = 0
    @x = 0
    @lineno = 0
    @name = name
    @filename = @name if @name && File.exist?(@name)
    @lines = lines
    @mode = :screen
    @line_mode = true
    @following_mode = following_mode

    @mouse = false
    @search = search
    @search_ignore_case = false
    @search_regexp = true
    @loading = false
    @buffer_lines = 10_000
    @yq = Queue.new
    @load_unlimited = false
    @prev_render = {}

    read_async input if input

    sleep 0.001
  end

  def read_async input
    @loading = true
    @reader_thread = Thread.new do
      while line = input.gets
        line = line.chomp
        line.instance_variable_set(:@lineno, @lineno += 1)
        @lines << line
        while !@load_unlimited && @lines.size > @y + @buffer_lines
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

  attr_reader :y
  def y_max
    @lines.size - Curses.lines + 2
  end

  def y=(y)
    if y > (ym = self.y_max)
      @y = ym
    else
      @y = y
    end

    @y = 0 if @y < 0
    @yq << nil if @loading
  end

  attr_reader :x

  def x=(x)
    @x = x
    @x = 0 if @x < 0
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

    if c_cols != @prev_render[:c_cols] ||
       c_lines != @prev_render[:c_lines] ||
       @y != @prev_render[:y] ||
       @x != @prev_render[:x] ||
       @search != @prev_render[:search] ||
       @line_mode != @prev_render[:line_mode] ||
       (!@prev_render[:render_full] && @lines.size != @prev_render[:lines_size])
      # OK
    else
      return
    end

    Curses.clear

    render_full = :not_full !=
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
        break :not_full
      end

      Curses.setpos i, 0

      if @line_mode
        cattr LINE_ATTR do
          ln_str = '%5d |' % line.instance_variable_get(:@lineno)
          Curses.addstr(ln_str)
          cols -= ln_str.size
        end
      end

      line = line[@x, cols] || ''

      if !@search
        Curses.addstr line
      else
        partition(line, @search).each{|(matched, str)|
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

    @prev_render = {c_cols: c_cols, c_lines: c_lines, x: @x, y: @y,
                    search: @search, line_mode: @line_mode,
                    render_full: render_full, lines_size: @lines.size}
  end

  def search_str
    if @search
      @search.instance_variable_get(:@search_str)
    else
      nil
    end
  end

  def render_status
    name = @name ? "<#{@name}>" : ''
    mouse  = @mouse ? ' [MOUSE]' : ''
    search = @search ? " search[#{search_str}]" : ''
    loading = @loading ? " (loading...#{@load_unlimited ? '!' : nil}#{@following_mode ? ' following' : ''}) " : ''
    x = @x > 0 ? " x:#{@x}" : ''
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
        self.y = self.y_max if @following_mode
      end

      if @following_mode
        @following_mode = false
        @load_unlimited = false
      end
      return ev
    end
  end

  def search_next start
    (start...@lines.size).each{|i|
      line = @lines[i]
      if @lines[i].match(@search)
        self.y = i
        return true
      end
    }
    screen_status "not found: [#{self.search_str}]"
    pause
  end

  def search_prev start
    start.downto(0){|i|
      if @lines[i].match(@search)
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
      raise KV_PopScreen

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
        self.y = ystr.to_i - 1
      end

    when 'F'
      @following_mode = true
      @load_unlimited = true
      @yq << true

    when 'L'
      @load_unlimited = !@load_unlimited
      @yq << true

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
            @search = Regexp.compile(search_str, *ic)
          rescue RegexpError => e
            @search = nil
            screen_status "regexp compile error: #{e.message}"
            pause
          end
        else
          @search = Regexp.compile(Regexp.escape(search_str), *ic)
        end
      else
        @search = nil
      end
      if @search
        @search.instance_variable_set(:@search_str, search_str)
        search_next self.y
      end
    when 'n'
      search_next self.y+1 if @search
    when 'p'
      search_prev self.y-1 if @search
    when 'f'
      if @search
        filter_mode_title = "*filter mode [#{self.search_str}]*"
        if @name != filter_mode_title
          lines = @lines.grep(@search)
          fscr = KV_Screen.new nil, lines: lines, search: @search, name: filter_mode_title
          raise KV_PushScreen.new(fscr)
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
      @line_mode = !@line_mode
    when 't'
      Curses.close_screen
      @mode = :terminal

    when '?'
      raise KV_PushScreen.new(KV_Screen.new help_io)

    else
      screen_status "unknown: #{key_name(ev)}"
      pause
    end
  end

  def control_terminal
    binding.irb

    @mode = :screen
    init_screen
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
end

class KV
  def initialize argv
    @following_mode = false

    files = parse_option(argv)

    @pipe_in = nil

    if files.empty?
      if STDIN.isatty
        input = help_io
        name = 'HELP'
      else
        input = STDIN.dup
        STDIN.reopen('/dev/tty')
        trap(:INT){
          log "SIGINT"
        }
        name = nil
        @pipe_in = input
      end
    else
      input = open(name = ARGV.shift)
    end

    @screens = [KV_Screen.new(input, name: name, following_mode: @following_mode)]
  end

  def parse_option argv
    opts = OptionParser.new
    opts.on('-f'){
      @following_mode = true
    }
    opts.parse!(argv)
  end

  def control
    @screens.last.init_screen
    until @screens.empty?
      begin
        @screens.last.control
      rescue KV_PopScreen
        @screens.pop
      rescue KV_PushScreen => e
        @screens.push e.screen
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
      f.puts "#{prefix}#{obj.class}: #{obj.inspect}"
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
