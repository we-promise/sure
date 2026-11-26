require "test_helper"

class ReceiptScan::ImageNormalizerTest < ActiveSupport::TestCase
  test "normalizes rotated jpeg" do
    result = normalize("rotated.jpg", "image/jpeg")

    assert_upright_stripped_jpeg(result)
    assert_equal "rotated.jpg", result[:filename]
  end

  test "normalizes rotated heic" do
    skip "libvips can't decode HEIC here" unless heic_decodable?

    result = normalize("rotated.heic", "image/heic")

    assert_upright_stripped_jpeg(result)
    assert_equal "rotated.jpg", result[:filename]
  end

  test "passes pdf through" do
    original = file_fixture("receipts/receipt.pdf").binread

    result = normalize("receipt.pdf", "application/pdf")

    assert_equal "application/pdf", result[:content_type]
    assert_equal original, result[:io].read.b
  end

  test "sniffs a photo uploaded without a usable content type" do
    %w[application/octet-stream].push("").each do |declared|
      result = normalize("rotated.jpg", declared)

      assert_upright_stripped_jpeg(result)
    end
  end

  test "sniffs a pdf uploaded as octet-stream" do
    result = normalize("receipt.pdf", "application/octet-stream")

    assert_equal "application/pdf", result[:content_type]
  end

  test "rejects text file" do
    assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) do
      ReceiptScan::ImageNormalizer.call(io: StringIO.new("hello"), content_type: "text/plain", filename: "a.txt")
    end
  end

  test "rejects a file whose bytes are not the declared image type" do
    File.open(file_fixture("receipts/receipt.pdf"), "rb") do |io|
      assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) do
        ReceiptScan::ImageNormalizer.call(io:, content_type: "image/jpeg", filename: "fake.jpg")
      end
    end
  end

  test "a file of another type is rejected before libvips opens it" do
    Vips::Image.expects(:new_from_file).never

    File.open(file_fixture("receipts/receipt.pdf"), "rb") do |io|
      assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) do
        ReceiptScan::ImageNormalizer.call(io:, content_type: "image/jpeg", filename: "fake.jpg")
      end
    end
  end

  test "an image whose pixels can't be decoded is an unsupported file, not an error" do
    ImageProcessing::Builder.any_instance.stubs(:call).raises(Vips::Error, "VipsJpeg: Premature end of JPEG file")

    assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) { normalize("rotated.jpg", "image/jpeg") }
  end

  test "rejects a pdf without a pdf signature" do
    assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) do
      ReceiptScan::ImageNormalizer.call(io: StringIO.new("<html>"), content_type: "application/pdf", filename: "x.pdf")
    end
  end

  test "rejects an svg declared as png" do
    svg = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>'

    assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) do
      ReceiptScan::ImageNormalizer.call(io: StringIO.new(svg), content_type: "image/png", filename: "x.png")
    end
  end

  test "rejects images over the pixel limit" do
    png = Vips::Image.black(9000, 6000).pngsave_buffer(compression: 9)

    assert_raises(ReceiptScan::ImageNormalizer::UnsupportedFile) do
      ReceiptScan::ImageNormalizer.call(io: StringIO.new(png), content_type: "image/png", filename: "bomb.png")
    end
  end

  private
    # Some libvips builds list .heic but have no HEVC decoder, so only decoding pixels tells.
    def heic_decodable?
      Vips.get_suffixes.include?(".heic") && Vips::Image.new_from_file(file_fixture("receipts/rotated.heic").to_s).avg.present?
    rescue Vips::Error
      false
    end

    def normalize(name, content_type)
      File.open(file_fixture("receipts/#{name}"), "rb") do |io|
        ReceiptScan::ImageNormalizer.call(io:, content_type:, filename: name)
      end
    end

    def assert_upright_stripped_jpeg(result)
      assert_equal "image/jpeg", result[:content_type]
      image = Vips::Image.new_from_buffer(result[:io].read, "")
      assert_operator image.height, :>, image.width
      assert_equal 2000, [ image.width, image.height ].max
      assert_empty image.get_fields.grep(/exif|GPS/)
    end
end
