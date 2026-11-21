# The one input step before `extract_pdf`'s generations: which way a PDF is read, and in which
# order.
#
#   :pdf     the PDF itself, when the model has `documents` and the file is within the preset's
#            inline limits (Anthropic and OpenAI's own API)
#   :text    the text layer (Pdf::TextExtractor), page by page, packed into batches by tokens
#   :images  page images at 150 dpi, when the model has `vision`
#   :ocr     an OCR route entry (a model with `ocr`) transcribes the pages, then the text model
#            reads the transcription like a text layer
#
# Auto tries them in that order, starting from `start:`, the way that last passed for the same
# account and model (PdfImport.last_passing_way). A way it can't use is skipped: an empty text
# layer is never sent. A statement whose extraction fails its checks moves on to the next way;
# when nothing passes, the best extraction is kept and flagged for review, never dropped (#3105,
# #1753). "Read as" (`read_as:`) runs one way only.
class Ai::PdfReading
  WAYS = %i[pdf text images ocr].freeze
  READ_AS = %i[auto pdf images ocr text].freeze
  # Errors that end one way and move to the next: the model can't take this input, or its
  # answer wasn't usable. An outage isn't one of them: reading another way won't get round it.
  NEXT_WAY = [ Ai::Error::Refused, Ai::Error::InvalidOutput, Ai::Error::ContextTooLong, Ai::Error::Unavailable ].freeze
  # Characters per text unit: a page longer than this is split, so a small local model's window
  # (2,048 tokens by default) still takes one unit (#808).
  MIN_CHUNK_CHARS = 2_000
  # Batches ReadPdf may read to find a statement past a generic cover page.
  CLASSIFY_BATCHES = 3
  # The document types whose transactions are extracted.
  STATEMENT_TYPES = %w[bank_statement credit_card_statement].freeze
  # Characters per text unit for a model whose window isn't known.
  UNKNOWN_WINDOW_CHUNK_CHARS = 3_000

  Outcome = Data.define(:value, :way, :model, :checks, :usage, :attempts) do
    def passed? = checks.nil? || checks.passed?
    def flagged? = !passed?
  end

  # The OCR text layer, and the pages no route could transcribe: those rows can still net to the
  # printed balances, so an extraction from this text is flagged incomplete.
  Transcription = Data.define(:pages, :untranscribed_pages) do
    def text = pages.join("\n")
  end

  attr_reader :content, :filename, :family, :user

  # What the route can do before a file is chosen, for the "Read as" options: each way with why
  # the route can't, or nil. Text and Auto are always offered; the file decides the rest.
  def self.route_reasons(family:, user: nil)
    plan = Ai::Router.new(family:, user:).resolve(:extract_pdf)
    return WAYS.index_with { :not_configured } unless plan.is_a?(Ai::Plan)

    models = plan.routes.map(&:model)
    readers = models.select { _1.capable?(:structured_output) }
    { pdf: (:needs_documents unless readers.any? { _1.capable?(:documents) }), text: nil,
      images: (:needs_vision unless readers.any? { _1.capable?(:vision) }),
      ocr: (:needs_ocr_route unless models.any? { _1.capable?(:ocr) } && readers.any?) }
  end

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
    each_way(read_as, start:, attempts:, cancelled:, keep: -> { best }) do |way, units, source, untranscribed_pages|
      result = Ai::Generations::ExtractBankStatement.new(units:, content:, filename:, family:, user:).call(plan:, cancelled:)
      result.value!

      balances = printed_balances(source)
      # The checks reconcile against the balances printed in the text layer. Keep those values in
      # the retained extraction too: PdfImport#extract_transactions stores them as the statement's
      # balances, and the model's own figures can be wrong even when the rows reconcile.
      value = balances.empty? ? result.value : result.value.merge(balances)
      checks = Ai::Generations::ExtractBankStatement.checks(value, source:, balances:)
                                                    .with(complete: result.skipped.empty? && result.remaining.empty? && untranscribed_pages.blank?)
      outcome = Outcome.new(value:, way:, model: result.route&.model&.name, checks:, usage: result.usage, attempts:)
      attempts << { way:, checks: checks.to_h }
      return outcome unless checks.worth_another_way? || balances_unknown?(checks, source)

      best = outcome if best.nil? || checks.score > best.checks.score
      nil
    end
    best || raise_unavailable(attempts)
  end

  # What the document is (ReadPdf), from the first way that answers. A batch at a time: the first
  # is usually enough, but a cover page can say nothing, so later batches are read, up to
  # CLASSIFY_BATCHES, until one says it's a statement. Otherwise the first batch's answer stands.
  def read(read_as: :auto, cancelled: nil)
    attempts = []
    each_way(read_as, attempts:, cancelled:) do |way, units, _source|
      first = nil
      usage = nil
      CLASSIFY_BATCHES.times do
        begin
          result = Ai::Generations::ReadPdf.new(units:, content:, filename:, family:, user:).call(batches: 1, plan:, cancelled:)
          result.value!
        rescue Ai::Error::Cancelled
          raise
        rescue Ai::Error::Base, Pdf::PageImages::Error => error
          # A lookahead past a generic cover page can fail on its own. The first batch's answer
          # stands; a failure before any answer ends this way.
          raise error if first.nil?

          break
        end
        first ||= result
        usage = [ usage, result.usage ].compact.reduce(:+)
        if STATEMENT_TYPES.include?(result.value[:document_type])
          first = result
          break
        end
        break if result.remaining.empty?

        units = result.remaining
      end

      attempts << { way: }
      return Outcome.new(value: first.value, way:, model: first.route&.model&.name, checks: nil, usage:, attempts:)
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
    # `keep` answers whether an extraction is already in hand: an outage on a later way (a 5xx, a
    # timeout, an unreachable server) then ends the search with that extraction, flagged, rather
    # than failing the import. With nothing in hand the outage is raised to the caller.
    def each_way(read_as, attempts:, start: nil, cancelled: nil, keep: -> { nil })
      order(read_as, start:).each do |way|
        reason = reason_for(way)
        if reason
          attempts << { way:, error: reason }
          next
        end

        begin
          units, source, untranscribed_pages = units_for(way, cancelled:)
          yield way, units, source, untranscribed_pages
        rescue Ai::Error::Cancelled
          raise   # a cancellation ends the whole import, not just this way
        rescue *NEXT_WAY => error
          attempts << { way:, error: error.is_a?(Ai::Error::Unavailable) ? error.reason : error.class.name.demodulize }
        rescue Pdf::PageImages::Error => error
          # The pages couldn't be rendered (pdftoppm missing, a page too large): another way may
          # still read the file, and an extraction in hand is kept.
          Rails.logger.warn("[Ai::PdfReading] #{way}: #{error.message}")
          attempts << { way:, error: :unreadable, render_error: error.code }
        rescue Ai::Error::Base => error
          raise unless keep.call

          attempts << { way:, error: error.class.name.demodulize }
          break
        end
      end
    end

    # A scan nothing on the route can read is `no_text_layer`; otherwise the last
    # way's reason. A failed renderer's code stays on the error for the admin's status page.
    def raise_unavailable(attempts)
      render_error = attempts.filter_map { _1[:render_error] }.last
      reason = text_layer? ? attempts.filter_map { _1[:error] }.last || ways.values.compact.first :
               render_error ? :unreadable : :no_text_layer
      raise Ai::Error::Unavailable.new(reason || :no_way_to_read, code: render_error)
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
        return :needs_ocr_route unless ocr_routes.any?

        :unreadable unless page_count
      end
    end

    # [units, the text the model reads or nil, pages nothing read: no OCR route could transcribe
    # them, or the text layer was empty for a page that may still hold a scan].
    def units_for(way, cancelled: nil)
      case way
      when :pdf then [ [ Ai::PdfReading::Unit.pdf(page_count || 1) ], nil, [] ]
      when :text then text_units(text_pages)
      when :images then [ (1..page_count).map { Ai::PdfReading::Unit.page(_1) }, nil, [] ]
      when :ocr
        transcription = transcribe(cancelled:)
        units, source = text_units(transcription.pages)
        [ units, source, transcription.untranscribed_pages ]
      end
    end

    def text_units(pages)
      limit = chunk_chars
      units, blank_pages = [], []
      pages.each_with_index do |text, index|
        if text.strip.empty?
          blank_pages << index + 1
          next
        end
        position = 0
        while position < text.length
          finish = [ position + limit, text.length ].min
          if finish < text.length
            newline = text.rindex("\n", finish - 1)
            finish = newline + 1 if newline && newline >= position
          end
          units << Ai::PdfReading::Unit.text(text[position...finish], page: index + 1)
          position = finish
        end
      end
      raise Ai::Error::Unavailable, :no_text_layer if units.empty?

      # A blank text page can be a scan with no text layer. It isn't in skipped or remaining, so
      # report it here or a mixed PDF would be marked complete with transactions missing.
      [ units, pages.join("\n"), blank_pages ]
    end

    # Half the model's window for one unit, so the prompt and the answer still fit.
    def chunk_chars
      budget = model && Ai::Batch.budget_for(model, 0)
      budget ? [ budget * 2, MIN_CHUNK_CHARS ].max : UNKNOWN_WINDOW_CHUNK_CHARS
    end

    # One OCR request per page: a local OCR model takes ~45 s a page on CPU, so each request
    # keeps within the endpoint's timeout, and Mistral and Cohere bill per page anyway. A page a
    # route can't read goes to the next route; a route that times out is skipped for later pages.
    # A page no route can read is left blank and counted, so Auto can still extract from the rest
    # and flag the result incomplete.
    def transcribe(cancelled: nil)
      return @transcription if @transcription

      routes = ocr_routes
      # Marked down by another worker since reason_for(:ocr) found it: this way ends, before rendering.
      raise Ai::Error::Unavailable, :needs_ocr_route if routes.empty?

      untranscribed = []
      timed_out = []
      pages = (1..page_count).map do |number|
        raise Ai::Error::Cancelled, "cancelled" if cancelled&.call

        text, = transcribe_page(number, routes, timed_out:, cancelled:)
        untranscribed << number unless text
        text || ""
      end
      transcription = Transcription.new(pages:, untranscribed_pages: untranscribed)
      # A scan whose every page failed is no text layer: don't cache it, so Auto can try another
      # way (and a later call can retry) rather than reusing an empty transcription.
      @transcription = transcription if pages.any?(&:present?)
      transcription
    end

    # [the page's text, or nil when every route refused or couldn't read it].
    def transcribe_page(number, routes, timed_out:, cancelled:)
      png = Pdf::PageImages.render(content, pages: [ number ]).first
      routes.each do |route|
        next if timed_out.include?(route) || Ai::DownMarks.down?(route)
        raise Ai::Error::Cancelled, "cancelled" if cancelled&.call

        begin
          request = Ai::Transport::Base::OcrRequest.new(feature: :extract_pdf, family:, model: route.model,
                                                        pages: [ Ai::Attachment.png(png, filename: "page-#{number}.png") ])
          text = route.transport.ocr(request).text.to_s.strip
          return [ text, nil ] if text.present?

          Rails.logger.warn("[Ai::PdfReading] OCR page #{number}: #{route.model.name} returned no text")
        rescue *NEXT_WAY, Ai::Error::Timeout => error
          # A refusal, unusable answer or timeout ends this route's try at this page, not the
          # whole way: a later OCR route may still transcribe it. A timed-out route is slow enough
          # that retrying it on every later page risks the whole job, so skip it for this run.
          # Never log the provider's message: it can carry account numbers or other identifiers.
          timed_out << route if error.is_a?(Ai::Error::Timeout)
          Rails.logger.warn("[Ai::PdfReading] OCR page #{number} on #{route.model.name}: #{error.class.name} (status=#{error.status.inspect})")
        end
      end
      [ nil, :unreadable ]
    end

    def text_routes = plan.routes.select { _1.model.capable?(:structured_output) }

    # The first live OCR route, then any others: one model's refusal at a page needn't lose it.
    def ocr_routes
      primary = ocr_route
      return [] unless primary

      [ primary, *plan.routes.select { _1.model.capable?(:ocr) && _1 != primary && !Ai::DownMarks.down?(_1) } ]
    end

    def ocr_route = plan.routes.find { _1.model.capable?(:ocr) && !Ai::DownMarks.down?(_1) }

    # The balances printed on the statement, by #4054's parser: from its text layer, else from the
    # text the model read (an OCR transcription). Models write figures to fit their rows, so
    # `reconciles` trusts these over the model's.
    # Only balances failed, and nothing shows the statement prints none: no text to look in (a scan
    # read as images), so another way (OCR) may still find them.
    def balances_unknown?(checks, source)
      checks.failed == %i[balances] && !text_layer? && source.blank?
    end

    # A source with both balances wins over one with only one of them.
    def printed_balances(source)
      parsed = [ text_pages.join("\n"), source ].compact.uniq.map { parsed_balances(_1) }
      parsed.find { _1.size == 2 } || parsed.find(&:present?) || {}
    end

    def parsed_balances(text)
      parsed = AccountStatement::TextMetadataParser.parse(text)
      { opening_balance: parsed&.opening_balance, closing_balance: parsed&.closing_balance }.compact
    rescue StandardError
      {}
    end
end
