# The one input step before `extract_pdf`'s generations (section 8.1), replacing today's three
# per-provider classes: which way a PDF is read, and in which order.
#
#   :pdf     the PDF itself, when the model has `documents` and the file is within the preset's
#            inline limits (Anthropic and OpenAI's own API)
#   :text    the text layer (Pdf::TextExtractor), page by page, packed into batches by tokens
#   :images  page images at 150 dpi, when the model has `vision`
#   :ocr     an OCR route entry (a model with `ocr`) transcribes the pages, then the text model
#            reads the transcription like a text layer
#
# Auto tries them in that order, starting from the way that last passed for the same account and
# model (Auto tunes itself, a lookup the caller passes as `start:`). A way it can't use is
# skipped: an empty text layer is never sent. A statement whose extraction fails its checks
# moves on to the next way; when nothing passes, the best extraction is kept and flagged for
# review, never dropped (#3105, #1753). "Read as" (`read_as:`) runs one way only.
class Ai::PdfReading
  WAYS = %i[pdf text images ocr].freeze
  READ_AS = %i[auto pdf images ocr text].freeze
  # Errors that end one way and move to the next: the model can't take this input, or its
  # answer wasn't usable. An outage ends the reading, so the job can try again later.
  NEXT_WAY = [ Ai::Error::Refused, Ai::Error::InvalidOutput, Ai::Error::ContextTooLong, Ai::Error::Unavailable ].freeze
  # Characters per text unit: a page longer than this is split, so a small local model's window
  # (2,048 tokens by default) still takes one unit (#808).
  MIN_CHUNK_CHARS = 2_000

  Outcome = Data.define(:value, :way, :model, :checks, :usage, :attempts) do
    def passed? = checks.nil? || checks.passed?
    def flagged? = !passed?
  end

  attr_reader :content, :filename, :family, :user

  def initialize(content:, family:, filename: "document.pdf", user: nil, plan: nil)
    @content, @filename, @family, @user, @plan = content, filename, family, user, plan
  end

  # The plan for `extract_pdf`, or Ai::Error::Unavailable with the router's reason.
  def plan
    @plan ||= Ai::Router.new(family:, user:).resolve(:extract_pdf)
    raise Ai::Error::Unavailable, @plan.reason unless @plan.is_a?(Ai::Plan)

    @plan
  end

  # The model the generations go to first: what Auto's tuning is keyed by.
  def model = text_routes.first&.model

  # Each way, with why it can't be used here, or nil when it can.
  def ways = WAYS.index_with { reason_for(_1) }

  # The ways to try, in order. `start` comes first when it's usable (Auto's tuning).
  def order(read_as = :auto, start: nil)
    read_as = read_as.to_s.presence&.to_sym || :auto
    raise ArgumentError, "unknown way #{read_as.inspect}" unless READ_AS.include?(read_as)
    return [ read_as ] if read_as != :auto

    usable = WAYS.select { ways[_1].nil? }
    start = start&.to_sym
    usable.include?(start) ? [ start ] + (usable - [ start ]) : usable
  end

  # The statement's extraction (ExtractBankStatement), checked, from the first way that passes.
  def extract(read_as: :auto, start: nil, cancelled: nil)
    attempts = []
    best = nil
    each_way(read_as, start:, attempts:) do |way, units, source|
      result = Ai::Generations::ExtractBankStatement.new(units:, content:, filename:, family:, user:).call(plan:, cancelled:)
      result.value!

      checks = Ai::Generations::ExtractBankStatement.checks(result.value, source:, balances: printed_balances)
      outcome = Outcome.new(value: result.value, way:, model: result.route&.model&.name, checks:, usage: result.usage, attempts:)
      attempts << { way:, checks: checks.to_h }
      return outcome.with(attempts:) if checks.passed?

      best = outcome if best.nil? || checks.score > best.checks.score
      nil
    end
    best&.with(attempts:) || raise_unavailable(attempts)
  end

  # What the document is (ReadPdf), from the first way that answers.
  def read(read_as: :auto, cancelled: nil)
    attempts = []
    each_way(read_as, attempts:) do |way, units, _source|
      result = Ai::Generations::ReadPdf.new(units:, content:, filename:, family:, user:).call(batches: 1, plan:, cancelled:)
      result.value!

      attempts << { way: }
      return Outcome.new(value: result.value, way:, model: result.route&.model&.name, checks: nil, usage: result.usage, attempts:)
    end
    raise_unavailable(attempts)
  end

  # The text layer, page by page ("" for a page without one).
  def text_pages
    @text_pages ||= Pdf::TextExtractor.pages(content)
  rescue StandardError => error
    Rails.logger.warn("[Ai::PdfReading] no text layer: #{error.class}: #{error.message}")
    @text_pages = []
  end

  def text_layer? = text_pages.any? { _1.strip.present? }

  def page_count
    @page_count ||= Pdf::PageImages.page_count(content)
  rescue Pdf::PageImages::Error
    nil
  end

  private
    def each_way(read_as, attempts:, start: nil)
      order(read_as, start:).each do |way|
        reason = reason_for(way)
        if reason
          attempts << { way:, error: reason }
          next
        end

        begin
          units, source = units_for(way)
          yield way, units, source
        rescue *NEXT_WAY => error
          attempts << { way:, error: error.is_a?(Ai::Error::Unavailable) ? error.reason : error.class.name.demodulize }
        end
      end
    end

    # A scan nothing on the route can read is `no_text_layer` (section 8.1); otherwise the last
    # way's reason.
    def raise_unavailable(attempts)
      reason = text_layer? ? attempts.filter_map { _1[:error] }.last || ways.values.compact.first : :no_text_layer
      raise Ai::Error::Unavailable, reason || :no_way_to_read
    end

    def reason_for(way)
      case way
      when :pdf
        return :needs_documents unless text_routes.any? { _1.model.capable?(:documents) }

        limits = text_routes.find { _1.model.capable?(:documents) }.endpoint.pdf_limits
        :too_large if limits && (content.bytesize > limits[:bytes] || page_count.to_i > limits[:pages])
      when :text then :no_text_layer unless text_layer?
      when :images
        return :needs_vision unless text_routes.any? { _1.model.capable?(:vision) }

        :unreadable unless page_count
      when :ocr
        return :needs_ocr_route unless ocr_route

        :unreadable unless page_count
      end
    end

    # [units, the text the model reads or nil].
    def units_for(way)
      case way
      when :pdf then [ [ Ai::PdfReading::Unit.pdf(page_count || 1) ], nil ]
      when :text then text_units(text_pages)
      when :images then [ (1..page_count).map { Ai::PdfReading::Unit.page(_1) }, nil ]
      when :ocr then text_units(transcribe)
      end
    end

    def text_units(pages)
      limit = chunk_chars
      units = pages.each_with_index.flat_map do |text, index|
        next [] if text.strip.empty?

        text.scan(/.{1,#{limit}}/m).map { Ai::PdfReading::Unit.text(_1, page: index + 1) }
      end
      raise Ai::Error::Unavailable, :no_text_layer if units.empty?

      [ units, pages.join("\n") ]
    end

    # Half the model's window for one unit, so the prompt and the answer still fit.
    def chunk_chars
      budget = model && Ai::Batch.budget_for(model, 0)
      budget ? [ budget * 2, MIN_CHUNK_CHARS ].max : 12_000
    end

    # One OCR request per page: a local OCR model takes ~45 s a page on CPU, so each request
    # keeps within the endpoint's timeout, and Mistral and Cohere bill per page anyway.
    def transcribe
      route = ocr_route
      (1..page_count).map do |page|
        png = Pdf::PageImages.render(content, pages: page..page).first
        request = Ai::Transport::Base::OcrRequest.new(feature: :extract_pdf, family:, model: route.model,
                                                      pages: [ Ai::Attachment.png(png, filename: "page-#{page}.png") ])
        route.transport.ocr(request).text
      end
    end

    def text_routes = plan.routes.select { _1.model.capable?(:structured_output) }

    def ocr_route = plan.routes.find { _1.model.capable?(:ocr) && !Ai::DownMarks.down?(_1) }

    # The balances printed on the statement, read from its text layer (#4054), when found: models
    # write figures to fit their rows, so `reconciles` trusts the text first.
    def printed_balances
      @printed_balances ||= begin
        parsed = AccountStatement::TextMetadataParser.parse(text_pages.join("\n"))
        { opening_balance: parsed&.opening_balance, closing_balance: parsed&.closing_balance }.compact
      rescue StandardError
        {}
      end
    end
end
