# Turns a forwarded order email into plain text for the extraction model: the order's own HTML
# (or plain text) as readable lines, with the original sender, date and subject on top so the
# model reads the order date rather than the date it was forwarded.
class Purchase::EmailText
  MAX_CHARS = 40_000

  # original_from_domain: the registrable domain of whoever sent the order (the shop), read from
  # the forwarded block, the attached message, or an automatic forward's own From.
  # files: attachments that may be the purchase's receipt or invoice, normalized for the model.
  Result = Data.define(:text, :truncated, :input_chars, :original_from_domain, :files)

  FILE_CONTENT_TYPES = (ReceiptScan::ImageNormalizer::IMAGE_CONTENT_TYPES + [ "application/pdf" ]).freeze
  # Smaller images are logos and icons from signatures and HTML layouts. PDFs have no minimum:
  # a shop's e-receipt can be a few kilobytes.
  MIN_IMAGE_BYTES = 20.kilobytes
  MAX_FILE_BYTES = 10.megabytes
  MAX_FILES = 5
  # All of an email's files together, kept well inside a request's size once encoded.
  MAX_FILES_BYTES = 20.megabytes
  # Receipts and invoices run to a page or two; longer PDFs are terms, catalogues or manuals,
  # and the model accepts at most 100 PDF pages per request.
  MAX_PDF_PAGES = 5

  FORWARD_MARKERS = [
    /-{3,}\s*Forwarded message\s*-{3,}/i,
    /-{3,}\s*Wiadomość przekazana dalej\s*-{3,}/i,
    /-{3,}\s*Original Message\s*-{3,}/i,
    /Begin forwarded message:/i
  ].freeze
  # How far past a forward marker its header lines are looked for.
  FORWARD_BLOCK_CHARS = 2_000
  FORWARDED_HEADERS = {
    "Original-From" => /^\s*(?:From|Od):\s*(.+)$/i,
    "Original-Date" => /^\s*(?:Date|Data|Sent|Wysłano):\s*(.+)$/i,
    "Original-Subject" => /^\s*(?:Subject|Temat):\s*(.+)$/i
  }.freeze
  BLOCK_ELEMENTS = %w[p div br li tr h1 h2 h3 h4 h5 h6 table section article header footer].freeze

  # "Allegro <x@powiadomienia.allegro.pl>" -> "allegro.pl"; nil when no address can be read.
  def self.registrable_domain(address)
    host = address.to_s[/[^\s<>"@]+@([a-z0-9.-]+\.[a-z]{2,})/i, 1]
    PublicSuffix.domain(host.downcase) if host
  rescue PublicSuffix::Error
    nil
  end

  def initialize(mail)
    @mail = mail
  end

  def call
    message = innermost_message
    body = readable_body(message)
    headers = (inline_forward_headers(body) if message.equal?(mail)).presence || own_headers(message)
    text = [ header_block(headers), body ].reject(&:blank?).join("\n\n")

    Result.new(
      text: text.first(MAX_CHARS),
      truncated: text.length > MAX_CHARS,
      input_chars: text.length,
      original_from_domain: self.class.registrable_domain(headers["Original-From"]),
      files: receipt_files
    )
  end

  private
    attr_reader :mail

    # An order forwarded as an attachment sits in a message/rfc822 part.
    def innermost_message
      messages.last
    end

    # The email and each message forwarded inside it, outermost first.
    def messages
      @messages ||= [ mail ].tap do |chain|
        while (part = chain.last.all_parts.find { |candidate| candidate.mime_type == "message/rfc822" })
          chain << Mail.new(part.body.decoded)
        end
      end
    end

    # The same file can show up both in a forwarded message and in the email around it. Attached
    # files come before images embedded in the layout (product photos, banners), which would
    # otherwise take the slots ahead of an invoice; a phone's photo sent inline still counts.
    def receipt_files
      seen = Set.new
      parts = messages.flat_map(&:attachments).each_with_index.sort_by { |part, index| [ part.inline? ? 1 : 0, index ] }.map(&:first)
      parts.each_with_object([]) do |part, files|
        break files if files.size >= MAX_FILES
        next unless seen.add?(Digest::SHA256.digest(part.body.raw_source.to_s))

        file = receipt_file(part)
        next unless file
        next if files.sum { _1[:data].bytesize } + file[:data].bytesize > MAX_FILES_BYTES

        files << file
      end
    end

    # Labels some mail apps use for JPEG photos.
    CONTENT_TYPE_ALIASES = { "image/jpg" => "image/jpeg", "image/pjpeg" => "image/jpeg" }.freeze

    def receipt_file(part)
      content_type = part.mime_type.to_s.downcase
      content_type = CONTENT_TYPE_ALIASES.fetch(content_type, content_type)
      return unless content_type.in?(FILE_CONTENT_TYPES) || content_type.in?(ReceiptScan::ImageNormalizer::GENERIC_CONTENT_TYPES)

      data = part.decoded.to_s.b
      return if data.bytesize > MAX_FILE_BYTES
      return if data.bytesize < MIN_IMAGE_BYTES && !data.start_with?("%PDF-")

      normalized = ReceiptScan::ImageNormalizer.call(io: StringIO.new(data), content_type:, filename: part.filename.presence || "attachment")
      bytes = normalized[:io].read
      return if normalized[:content_type] == "application/pdf" && !readable_short_pdf?(bytes)

      { data: bytes, content_type: normalized[:content_type], filename: normalized[:filename] }
    rescue ReceiptScan::ImageNormalizer::UnsupportedFile, Vips::Error
      nil
    end

    # Encrypted or broken PDFs would make the model reject the whole request.
    def readable_short_pdf?(bytes)
      reader = PDF::Reader.new(StringIO.new(bytes))
      reader.objects.trailer[:Encrypt].nil? && reader.page_count <= MAX_PDF_PAGES
    rescue StandardError
      false
    end

    def readable_body(message)
      html = message.html_part || (message.mime_type == "text/html" ? message : nil)
      return html_to_text(decode(html)) if html

      plain = message.text_part || (message.multipart? ? nil : message)
      plain ? squeeze(decode(plain)) : ""
    end

    def decode(part)
      text = part.decoded.to_s
      text = text.dup.force_encoding(part.charset) if part.charset.present? && text.encoding == Encoding::BINARY
      text.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
    rescue ArgumentError, Encoding::ConverterNotFoundError
      part.body.decoded.to_s.dup.force_encoding("UTF-8").scrub("?")
    end

    def html_to_text(html)
      document = Nokogiri::HTML(html)
      document.css("script, style, head, img, noscript").remove
      document.css("td, th").each { |cell| cell.add_next_sibling(Nokogiri::XML::Text.new(" | ", document)) }
      document.css(BLOCK_ELEMENTS.join(", ")).each { |node| node.add_next_sibling(Nokogiri::XML::Text.new("\n", document)) }
      squeeze(document.text.gsub(/ \| \n/, "\n"))
    end

    def squeeze(text)
      text.gsub("\r", "").gsub(/[ \t ]+/, " ").gsub(/ *\n */, "\n").gsub(/\n{3,}/, "\n\n").strip
    end

    def own_headers(message)
      {
        "Original-From" => message[:from]&.decoded,
        "Original-Date" => message[:date]&.decoded,
        "Original-Subject" => message.subject
      }
    end

    # The header lines right after a "Forwarded message" marker in an inline forward. An order
    # forwarded on again carries one block per forward; the innermost one with a sender is the
    # shop's.
    def inline_forward_headers(body)
      ends = FORWARD_MARKERS.flat_map { |pattern| body.to_enum(:scan, pattern).map { Regexp.last_match.end(0) } }
      ends.sort.reverse_each do |offset|
        block = body[offset, FORWARD_BLOCK_CHARS].lines.first(8).join
        headers = FORWARDED_HEADERS.transform_values { |pattern| block[pattern, 1]&.strip }.compact_blank
        return headers if headers["Original-From"]
      end
      {}
    end

    def header_block(headers)
      lines = headers.compact_blank.map { |name, value| "#{name}: #{value}" }
      lines << "Received-Date: #{mail[:date]&.decoded}" if mail[:date]
      lines.join("\n")
    end
end
