# Pages of a PDF as PNGs at 150 dpi, rendered by `pdftoppm` in a child process (#3275's choice
# of poppler-utils). The child process is what keeps poppler, C code parsing an upload, out of
# the worker's memory, and it only does that when it's hardened:
#
# - an empty environment, so the worker's API keys and database URL never reach poppler;
# - its own process group, killed and reaped with every child after `timeout` seconds;
# - CPU and address-space limits;
# - only the requested pages, so a batch that skips a page never renders it (no page limit);
# - each page's size checked before rendering, from its MediaBox (a page-size bomb would
#   allocate gigabytes), and after: a page poppler can't allocate comes back as a 1x1 PNG with
#   exit status 0, and would be sent to the model as the page. The page numbers poppler wrote
#   are checked too, so a partial render isn't sent as a complete batch.
#
# It still runs as the worker's user with its file access; confining that needs a sandbox
# (bubblewrap, a separate container).
module Pdf::PageImages
  # `code` is what the admin's AI status shows (#3275): :missing_binary, :timeout, :failed,
  # :too_large, :unreadable or :blank_page.
  class Error < StandardError
    attr_reader :code

    def initialize(message, code:)
      @code = code
      super(message)
    end
  end

  DPI = 150
  MAX_PIXELS = 25_000_000   # about 23 inches square at 150 dpi; US Letter is 2.1 million
  MIN_SIDE = 16
  LIMITS = { timeout: 30, cpu_seconds: 60, memory: 1.gigabyte }.freeze

  module_function

  def page_count(content) = readable { reader(content).page_count }

  # PNGs of `pages` (a 1-based Range or a list of page numbers; every page by default), in
  # order. Consecutive pages share one child; a gap is never rendered.
  def render(content, pages: nil, dpi: DPI, binary: "pdftoppm", **limits)
    limits = LIMITS.merge(limits)
    pdf = reader(content)
    wanted = pages_for(readable { pdf.page_count }, pages)
    check_size!(pdf, numbers: wanted, dpi:)

    executable = binary.include?("/") ? binary : ENV.fetch("PATH", "").split(":").map { File.join(_1, binary) }.find { File.executable?(_1) }
    raise Error.new("pdftoppm is not installed (poppler-utils)", code: :missing_binary) unless executable

    Dir.mktmpdir do |dir|
      input = File.join(dir, "input.pdf")
      File.binwrite(input, content)
      by_page = {}
      runs(wanted).each_with_index do |(first, last), index|
        prefix = File.join(dir, "run-#{index}", "page")
        Dir.mkdir(File.dirname(prefix))
        by_page.merge!(render_run(executable, input, prefix, first:, last:, dpi:, limits:))
      end

      missing = wanted - by_page.keys
      if missing.any?
        rendered = wanted.size - missing.size
        raise Error.new("pdftoppm rendered #{rendered} of #{wanted.size} pages (missing #{missing.join(", ")})", code: :failed)
      end

      wanted.map do |number|
        png = by_page.fetch(number)
        width, height = png.byteslice(16, 8).to_s.unpack("NN")
        if width.to_i < MIN_SIDE || height.to_i < MIN_SIDE
          raise Error.new("pdftoppm rendered page #{number} as #{width.to_i}x#{height.to_i}", code: :blank_page)
        end

        png
      end
    end
  end

  def pages_for(count, pages)
    numbers = case pages
              when nil then (1..count).to_a
              when Integer then [ pages ]
              else pages.to_a
              end.select { _1.is_a?(Integer) && _1.between?(1, count) }.uniq.sort
    raise Error.new("no pages #{pages} in a #{count}-page PDF", code: :unreadable) if numbers.empty?

    numbers
  end

  def runs(numbers) = numbers.chunk_while { |previous, number| number == previous + 1 }.map { [ _1.first, _1.last ] }

  # One pdftoppm child, its output keyed by the absolute page number from the filename.
  def render_run(executable, input, prefix, first:, last:, dpi:, limits:)
    pid = begin
      Process.spawn({}, executable, "-png", "-r", dpi.to_s, "-f", first.to_s, "-l", last.to_s, input, prefix,
                    unsetenv_others: true, pgroup: true, chdir: File.dirname(prefix), in: File::NULL, out: File::NULL, err: File::NULL,
                    rlimit_cpu: limits[:cpu_seconds], rlimit_as: limits[:memory])
    rescue SystemCallError => error
      raise Error.new("could not start pdftoppm: #{error.message}", code: :failed)
    end

    status = nil
    begin
      status = wait(pid, limits[:timeout])
    ensure
      kill_group(pid) unless status   # a timeout, or an interruption from outside: poppler doesn't outlive it
    end
    raise Error.new("pdftoppm took longer than #{limits[:timeout]}s", code: :timeout) unless status
    unless status.success?
      raise Error.new("pdftoppm failed (#{status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"})", code: :failed)
    end

    Dir[File.join(File.dirname(prefix), "#{File.basename(prefix)}-*.png")].to_h do |path|
      [ path[/-(\d+)\.png\z/, 1].to_i, File.binread(path) ]
    end
  end

  # From the pages' MediaBox, read by pdf-reader, which already parses every upload in process
  # for its text layer. A file it can't open is refused before poppler sees it.
  def check_size!(pdf, numbers:, dpi:)
    numbers.each do |number|
      box = readable { pdf.page(number).rectangles[:MediaBox] }   # resolved, even when the PDF stores it as a reference
      pixels = (box.width.abs * dpi / 72.0) * (box.height.abs * dpi / 72.0)
      if pixels > MAX_PIXELS
        raise Error.new("page #{number} would be #{(pixels / 1e6).round} million pixels at #{dpi} dpi", code: :too_large)
      end
    end
  end

  def reader(content) = readable { PDF::Reader.new(StringIO.new(content.to_s)) }

  def readable
    yield
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::InvalidPageError, ArgumentError => error
    raise Error.new("unreadable PDF: #{error.message}", code: :unreadable)
  end

  # The child's status, or nil once its deadline has passed; the caller kills and reaps it.
  def wait(pid, timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    nil
  end

  def kill_group(pid)
    Process.kill("KILL", -pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
  private_class_method :pages_for, :runs, :render_run, :check_size!, :reader, :readable, :wait, :kill_group
end
