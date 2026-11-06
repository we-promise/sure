require "test_helper"

# The hardened pdftoppm (2e plan, step 5), ported from the spike's page_images_test with PDFs
# built to misbehave and stand-in pdftoppm scripts.
class Pdf::PageImagesTest < ActiveSupport::TestCase
  setup do
    skip "pdftoppm isn't installed (poppler-utils)" unless system("pdftoppm", "-v", out: File::NULL, err: File::NULL)
  end

  test "renders every page as a PNG at 150 dpi, a scan included" do
    pages = Pdf::PageImages.render(statement("impact_scanned"))

    assert_equal 2, pages.size
    assert pages.all? { _1.start_with?("\x89PNG".b) }
    assert_equal [ [ 1275, 1650 ] ] * 2, pages.map { size(_1) }, "US Letter at 150 dpi"
    assert_equal [ [ 933, 1219 ] ], Pdf::PageImages.render(statement("bac_ocr")).map { size(_1) }
  end

  test "renders only the pages asked for, so a 300-page upload costs what a batch needs" do
    pdf = blank_pdf(pages: 300)

    pages, seconds = timed { Pdf::PageImages.render(pdf, pages: 11..15) }

    assert_equal 5, pages.size
    assert_operator seconds, :<, 10
    assert_equal 300, Pdf::PageImages.page_count(pdf)
  end

  test "a file that isn't a PDF is refused before pdftoppm runs" do
    error = assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.render("not a pdf") }
    assert_equal :unreadable, error.code
  end

  test "a page-size bomb is refused before rendering" do
    bomb = blank_pdf(pages: 1, size: [ 14_400, 14_400 ])   # 200 inches, PDF's largest page

    error = assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.render(bomb) }
    assert_equal :too_large, error.code
    assert_match "page 1 would be 900 million pixels at 150 dpi", error.message
  end

  test "a page pdftoppm couldn't allocate is caught, not sent as 1x1" do
    Dir.mktmpdir do |dir|
      one_pixel = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
      File.binwrite(File.join(dir, "1x1.png"), one_pixel)
      binary = fake_pdftoppm(dir, %(for last; do :; done; cp #{dir}/1x1.png "$last-1.png"))

      error = assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.render(statement("bac_ocr"), binary:) }
      assert_equal :blank_page, error.code
      assert_equal "pdftoppm rendered page 1 as 1x1", error.message
    end
  end

  test "pdftoppm gets an empty environment: no keys or database URL" do
    Dir.mktmpdir do |dir|
      binary = fake_pdftoppm(dir, "env > #{dir}/env; exit 1")
      ENV["SURE_SECRET_PROBE"] = "s3cret"

      error = assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.render(statement("bac_ocr"), binary:) }

      assert_equal :failed, error.code
      environment = File.read(File.join(dir, "env"))
      assert_no_match(/s3cret|DATABASE_URL|API_KEY|SECRET_KEY_BASE/, environment)
      assert_operator environment.lines.size, :<=, 3, "only what sh sets itself"
    ensure
      ENV.delete("SURE_SECRET_PROBE")
    end
  end

  test "a pdftoppm that hangs is killed, with its whole process group, after the timeout" do
    Dir.mktmpdir do |dir|
      pids = File.join(dir, "pids")
      binary = fake_pdftoppm(dir, "sleep 60 & echo $! > #{pids}; echo $$ >> #{pids}; wait")

      error, seconds = timed { assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.render(statement("bac_ocr"), binary:, timeout: 1) } }

      assert_equal :timeout, error.code
      assert_operator seconds, :<, 3
      File.read(pids).split.map(&:to_i).each do |pid|
        assert_raises(Errno::ESRCH, "process #{pid} survived") { Process.kill(0, pid) }
      end
    end
  end

  test "a missing pdftoppm keeps #3275's concrete reason" do
    error = assert_raises(Pdf::PageImages::Error) { Pdf::PageImages.render(statement("bac_ocr"), binary: "pdftoppm-not-here") }

    assert_equal :missing_binary, error.code
    assert_match "poppler-utils", error.message
  end

  private
    def statement(name) = file_fixture("statements/#{name}.pdf").binread

    def size(png) = png.byteslice(16, 8).unpack("NN")

    def timed
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      [ yield, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
    end

    # A stand-in for pdftoppm: a shell script, given the same arguments.
    def fake_pdftoppm(dir, body)
      File.join(dir, "fake-pdftoppm").tap { File.write(_1, "#!/bin/sh\n#{body}\n"); File.chmod(0o755, _1) }
    end

    # A minimal valid PDF of blank pages, each `size` points.
    def blank_pdf(pages:, size: [ 612, 792 ])
      objects = [ "<< /Type /Catalog /Pages 2 0 R >>",
                  "<< /Type /Pages /Kids [#{(0...pages).map { "#{3 + _1} 0 R" }.join(" ")}] /Count #{pages} >>" ] +
                Array.new(pages) { "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{size.join(" ")}] >>" }
      pdf = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map { |object, i| pdf.bytesize.tap { pdf << "#{i + 1} 0 obj\n#{object}\nendobj\n" } }
      xref = pdf.bytesize
      pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n" << offsets.map { format("%010d 00000 n \n", _1) }.join
      pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
    end
end
