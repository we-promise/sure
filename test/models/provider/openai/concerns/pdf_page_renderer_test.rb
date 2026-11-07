require "test_helper"

class Provider::Openai::Concerns::PdfPageRendererTest < ActiveSupport::TestCase
  class Host
    include Provider::Openai::Concerns::PdfPageRenderer
    public :render_pdf_pages
  end

  test "returns pages in numeric order once there are ten or more" do
    names = %w[page-01.png page-02.png page-10.png page-11.png page-2.png]
    Dir.stubs(:mktmpdir).yields("/tmp/fake")
    File.stubs(:binwrite)
    Dir.stubs(:glob).returns(names.map { |n| "/tmp/fake/#{n}" })
    File.stubs(:binread).with { |path| true }.returns("x")
    Host.any_instance.stubs(:system).returns(true)
    order = []
    File.stubs(:binread).with { |path| order << File.basename(path); true }.returns("x")

    Host.new.render_pdf_pages("%PDF")

    assert_equal %w[page-01.png page-02.png page-2.png page-10.png page-11.png], order
  end
end
