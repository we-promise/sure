# Read-only view of a raw alert email: decoded headers, sender domain and the
# body flattened to text lines, which is the shape the bank parsers work on.
class EmailAlert::MimeMessage
  MAX_BYTES = 2.megabytes

  attr_reader :raw

  def initialize(raw)
    @raw = raw.to_s.b
  end

  def mail
    @mail ||= Mail.new(raw)
  end

  def message_id
    mail.message_id.presence
  end

  def subject
    mail.subject.to_s.strip
  end

  def from_address
    Array(mail.from).first.to_s.downcase
  end

  def from_domain
    from_address.split("@", 2).last.to_s
  end

  def sent_at
    mail.date&.to_time
  end

  def dkim
    @dkim ||= EmailAlert::DkimVerifier.new(raw)
  end

  # Non-empty text lines in document order. HTML parts are preferred over plain
  # text because bank templates put label and value in separate table cells,
  # which keeps them on separate lines here.
  def lines
    @lines ||= begin
      if (html = part_body("text/html"))
        html_lines(html)
      else
        text_lines(part_body("text/plain").to_s)
      end
    end
  end

  def text
    lines.join("\n")
  end

  # Label => value pairs from HTML table rows laid out as label, optional colon
  # cell, value. An empty value cell is kept as "", which flattened lines cannot
  # express. Keys are downcased; the first occurrence of a label wins.
  def table_fields
    @table_fields ||= begin
      html = part_body("text/html")
      html ? extract_table_fields(Nokogiri::HTML(html)) : {}
    end
  end

  private

    def part_body(mime_type)
      part = if mail.multipart?
        mail.all_parts.find { |p| p.mime_type == mime_type && !p.attachment? }
      elsif mail.mime_type == mime_type || (mime_type == "text/plain" && mail.mime_type.nil?)
        mail
      end
      return nil unless part

      part.decoded.to_s.dup.force_encoding(part.charset.presence || "UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
    rescue Encoding::ConverterNotFoundError
      part.decoded.to_s.dup.force_encoding("UTF-8").scrub
    end

    def html_lines(html)
      doc = Nokogiri::HTML(html)
      doc.css("script, style, head").each(&:remove)
      doc.css("br").each { |br| br.replace("\n") }
      doc.xpath("//text()").flat_map { |node| node.text.split("\n") }.then { |parts| clean(parts) }
    end

    def extract_table_fields(doc)
      doc.css("tr").each_with_object({}) do |row, fields|
        next if row.at_css("table")

        cells = clean_cells(row.xpath("./td|./th").map(&:text))
        cells.shift if cells.first&.empty?
        label = cells.shift.to_s.sub(/\s*[:：]\s*\z/, "")
        cells.shift if [ ":", "：" ].include?(cells.first)
        next if label.empty? || cells.empty? || fields.key?(label.downcase)

        fields[label.downcase] = cells.first
      end
    end

    def clean_cells(texts)
      texts.map { |t| t.tr(" ", " ").gsub(/[[:space:]]+/, " ").strip }
    end

    def text_lines(text)
      clean(text.split(/\r?\n/))
    end

    def clean(parts)
      parts.map { |line| line.tr(" ", " ").gsub(/[[:space:]]+/, " ").strip }.reject(&:empty?)
    end
end
