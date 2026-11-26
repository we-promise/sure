# Turns an uploaded receipt photo into an upright, metadata-free JPEG small enough to send to a
# vision model: phones store rotation in EXIF, iPhones shoot HEIC (which Claude doesn't accept),
# and EXIF carries the location the photo was taken. PDFs pass through untouched.
class ReceiptScan::ImageNormalizer
  UnsupportedFile = Class.new(StandardError)
  # A PDF longer than a receipt or an invoice: only its first pages would be read.
  TooManyPages = Class.new(UnsupportedFile)

  # libvips picks a loader by sniffing the bytes, whatever the client declared, and some of its
  # loaders (SVG, PDF, Matlab, ...) are not ones we want running on uploads. Only these may.
  LOADERS_BY_CONTENT_TYPE = {
    "image/jpeg" => "jpegload",
    "image/png" => "pngload",
    "image/webp" => "webpload",
    "image/heic" => "heifload",
    "image/heif" => "heifload"
  }.freeze
  IMAGE_CONTENT_TYPES = LOADERS_BY_CONTENT_TYPE.keys.freeze
  # Types that say nothing about the file: mobile image pickers upload photos without one.
  GENERIC_CONTENT_TYPES = [ "", "application/octet-stream", "binary/octet-stream" ].freeze
  # Larger than any phone camera; guards against decompression bombs.
  MAX_PIXELS = 50_000_000
  MAX_DIMENSION = 2000
  JPEG_QUALITY = 85

  def self.call(io:, content_type:, filename:)
    new(io:, content_type:, filename:).call
  end

  def initialize(io:, content_type:, filename:)
    @io = io
    @filename = filename.to_s
    @content_type = resolve_content_type(content_type.to_s.downcase)
  end

  def call
    if content_type == "application/pdf"
      bytes = io.read.b
      raise UnsupportedFile, "Receipt file is not a PDF" unless bytes.start_with?("%PDF-")
      raise TooManyPages, "The PDF has more pages than a receipt" if page_count(bytes) > Ai::Generations::ExtractReceipt::MAX_PDF_PAGES

      return { io: StringIO.new(bytes), content_type: "application/pdf", filename: }
    end
    unless content_type.in?(IMAGE_CONTENT_TYPES)
      raise UnsupportedFile, "Unsupported receipt file type: #{content_type.presence || "unknown"}"
    end

    { io: StringIO.new(jpeg_bytes), content_type: "image/jpeg", filename: "#{File.basename(filename, ".*")}.jpg" }
  end

  private
    attr_reader :io, :content_type, :filename

    def page_count(bytes)
      Pdf::PageImages.page_count(bytes)
    rescue Pdf::PageImages::Error
      raise UnsupportedFile, "The PDF can't be read"
    end

    # The libvips loader check below still decides whether the bytes are acceptable.
    def resolve_content_type(declared)
      return declared unless declared.in?(GENERIC_CONTENT_TYPES)

      sniffed = Marcel::MimeType.for(io, name: filename)
      io.rewind if io.respond_to?(:rewind)
      sniffed.to_s.downcase
    end

    # Checks the loader libvips picks from the file's bytes before anything opens it, then
    # reads only the header for the image size.
    def verify_image!(path)
      expected = LOADERS_BY_CONTENT_TYPE.fetch(content_type).delete_suffix("load")
      unless Vips.vips_foreign_find_load(path).to_s.downcase.start_with?("vipsforeignload#{expected}")
        raise UnsupportedFile, "Receipt file content does not match #{content_type}"
      end

      header = Vips::Image.new_from_file(path, access: :sequential)
      loader = header.get("vips-loader").to_s
      unless loader.start_with?(LOADERS_BY_CONTENT_TYPE.fetch(content_type))
        raise UnsupportedFile, "Receipt file content does not match #{content_type}"
      end
      if header.width * header.height > MAX_PIXELS
        raise UnsupportedFile, "Receipt image is too large (#{header.width}x#{header.height})"
      end
    rescue Vips::Error
      raise UnsupportedFile, "Receipt file is not a readable #{content_type} image"
    end

    def jpeg_bytes
      Tempfile.create([ "receipt", File.extname(filename) ], binmode: true) do |source|
        IO.copy_stream(io, source)
        source.flush
        verify_image!(source.path)

        output = convert_to_jpeg(source.path)
        begin
          File.binread(output.path)
        ensure
          output.close!
        end
      end
    end

    # libvips decodes pixels lazily, so a readable header doesn't mean the image converts.
    def convert_to_jpeg(path)
      ImageProcessing::Vips
        .source(path)
        .autorot
        .resize_to_limit(MAX_DIMENSION, MAX_DIMENSION)
        .convert("jpg")
        .saver(quality: JPEG_QUALITY, strip: true)
        .call
    rescue Vips::Error
      raise UnsupportedFile, "Receipt image could not be decoded"
    end
end
