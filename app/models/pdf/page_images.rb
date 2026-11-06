# Pages of a PDF as PNGs at 150 dpi, rendered by `pdftoppm` in a child process (section 8.1,
# keeping #3275's choice of poppler-utils). The child process is what keeps poppler, C code
# parsing an upload, out of the worker's memory, and it only does that when it's hardened
# (spike: "Rendering pages"):
#
# - an empty environment, so the worker's API keys and database URL never reach poppler;
# - its own process group, killed with every child after `timeout` seconds;
# - CPU and address-space limits;
# - a page range, so pages are rendered only when a batch needs them (no page limit);
# - each page's size checked before rendering, from its MediaBox (a page-size bomb would
#   allocate gigabytes), and after: a page poppler can't allocate comes back as a 1x1 PNG with
#   exit status 0, and would be sent to the model as the page.
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

  # PNGs of `pages` (a 1-based Range; every page by default), in order.
  def render(content, pages: nil, dpi: DPI, binary: "pdftoppm", **limits)
    limits = LIMITS.merge(limits)
    first, last = range_for(content, pages)
    check_size!(content, first:, last:, dpi:)

    executable = binary.include?("/") ? binary : ENV.fetch("PATH", "").split(":").map { File.join(_1, binary) }.find { File.executable?(_1) }
    raise Error.new("pdftoppm is not installed (poppler-utils)", code: :missing_binary) unless executable

    Dir.mktmpdir do |dir|
      pdf = File.join(dir, "input.pdf")
      File.binwrite(pdf, content)
      pid = Process.spawn({}, executable, "-png", "-r", dpi.to_s, "-f", first.to_s, "-l", last.to_s, pdf, File.join(dir, "page"),
                          unsetenv_others: true, pgroup: true, chdir: dir, in: File::NULL, out: File::NULL, err: File::NULL,
                          rlimit_cpu: limits[:cpu_seconds], rlimit_as: limits[:memory])
      status = wait(pid, limits[:timeout])
      raise Error.new("pdftoppm took longer than #{limits[:timeout]}s", code: :timeout) unless status
      unless status.success?
        raise Error.new("pdftoppm failed (#{status.signaled? ? "signal #{status.termsig}" : "exit #{status.exitstatus}"})", code: :failed)
      end

      Dir[File.join(dir, "page-*.png")].sort_by { _1[/-(\d+)\.png\z/, 1].to_i }.map { File.binread(_1) }.each_with_index do |png, i|
        width, height = png.byteslice(16, 8).to_s.unpack("NN")
        if width.to_i < MIN_SIDE || height.to_i < MIN_SIDE
          raise Error.new("pdftoppm rendered page #{first + i} as #{width.to_i}x#{height.to_i}", code: :blank_page)
        end
      end
    end
  end

  def range_for(content, pages)
    count = page_count(content)
    first = [ pages&.first || 1, 1 ].max
    last = [ pages&.last || count, count ].min
    raise Error.new("no pages #{pages} in a #{count}-page PDF", code: :unreadable) if first > last

    [ first, last ]
  end

  # From the pages' MediaBox, read by pdf-reader, which already parses every upload in process
  # for its text layer. A file it can't open is refused before poppler sees it.
  def check_size!(content, first:, last:, dpi:)
    pages = readable { reader(content).pages[(first - 1)..(last - 1)] }
    pages.each_with_index do |page, i|
      left, bottom, right, top = page.attributes[:MediaBox] || [ 0, 0, 612, 792 ]
      pixels = ((right - left).abs * dpi / 72.0) * ((top - bottom).abs * dpi / 72.0)
      if pixels > MAX_PIXELS
        raise Error.new("page #{first + i} would be #{(pixels / 1e6).round} million pixels at #{dpi} dpi", code: :too_large)
      end
    end
  end

  def reader(content) = readable { PDF::Reader.new(StringIO.new(content.to_s)) }

  def readable
    yield
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, ArgumentError => error
    raise Error.new("unreadable PDF: #{error.message}", code: :unreadable)
  end

  # The child's status, or nil after killing its whole process group.
  def wait(pid, timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      _, status = Process.wait2(pid, Process::WNOHANG)
      return status if status
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    Process.kill("KILL", -pid)
    Process.wait(pid)
    nil
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end
  private_class_method :range_for, :check_size!, :reader, :readable, :wait
end
