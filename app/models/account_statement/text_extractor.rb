class AccountStatement
  # Reads a stored statement's text, page by page.
  #
  # Every MCP tool over the Statement Vault returns metadata only: an assistant
  # handed a loan amortization schedule got back a filename and a byte size, and
  # the user had to retype the contents. The bytes are held in Active Storage
  # but served only to an authorized browser session
  # (config/initializers/active_storage_authorization.rb), so a tool client has
  # no route to them at all.
  #
  # PDFs are read through Pdf::TextExtractor, the same extraction that backs
  # VectorStore::Embeddable and the statement metadata detector. This makes no
  # AI call. Image-only PDFs return no text, which is reported rather than
  # hidden, with the way PDF import could read the scan on this install:
  # images on a vision model, OCR on an OCR model, or nothing, so an assistant
  # never hunts for figures that were never extracted.
  class TextExtractor
    # CSV membership is AccountStatement's to decide: it accepts four content
    # types for .csv and a second partial list here reported a statement stored
    # as application/csv or application/vnd.ms-excel as unreadable.
    TEXT_CONTENT_TYPES = %w[text/plain application/json text/markdown].freeze

    # A text file has no pages, so it is cut into fixed-size chunks. Returning
    # the whole file as a single page defeated get_document_text's per-call
    # character budget: its window keeps the first page whole whatever its size,
    # so a large CSV came back entire in one response.
    TEXT_PAGE_CHARS = 3_000

    Result = Data.define(:pages, :page_count, :extractable, :note)

    def initialize(statement, user: nil)
      @statement = statement
      @user = user
    end

    def extract
      return unsupported("The file is no longer attached.") unless @statement.original_file.attached?

      content = @statement.original_file.download

      if @statement.pdf?
        extract_pdf(content)
      elsif @statement.csv? || TEXT_CONTENT_TYPES.include?(@statement.content_type)
        pages = paginate_text(encode(content))
        Result.new(pages: pages, page_count: pages.size, extractable: true, note: nil)
      else
        unsupported("Text extraction supports PDF and plain-text files. This file is #{@statement.content_type}.")
      end
    end

    private
      def extract_pdf(content)
        pages = Pdf::TextExtractor.pages(content).map { |text| encode(text) }

        if pages.all?(&:blank?)
          return Result.new(
            pages: [],
            page_count: pages.size,
            extractable: false,
            note: "The PDF has #{pages.size} page(s) but contains no extractable text layer, which means it is " \
                  "a scan, so its contents cannot be read here. #{scan_hint}"
          )
        end

        Result.new(pages: pages, page_count: pages.size, extractable: true, note: nil)
      rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
        unsupported("The PDF could not be parsed (#{e.class.name.demodulize}).")
      end

      # What PDF import's "Read as" can do with a scan for this family and user.
      def scan_hint
        reasons = Ai::PdfReading.route_reasons(family: @statement.family, user: @user)
        way = %i[images ocr].find { reasons[_1].nil? }
        if way
          "Importing it as a statement with \"Read as\" set to #{way == :images ? "Images" : "OCR"} can read the " \
            "scanned pages; suggest that, or ask the user for the figures. Don't guess."
        else
          "No model set up on this install can read scanned pages. Ask the user for the figures directly rather than guessing."
        end
      end

      def paginate_text(text)
        return [ "" ] if text.empty?

        (0...text.length).step(TEXT_PAGE_CHARS).map { |offset| text[offset, TEXT_PAGE_CHARS] }
      end

      def encode(text)
        text.to_s.encode("UTF-8", invalid: :replace, undef: :replace).strip
      end

      def unsupported(note)
        Result.new(pages: [], page_count: 0, extractable: false, note: note)
      end
  end
end
