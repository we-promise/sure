# Base class for per-institution alert parsers.
#
# A parser declares the sender domains it trusts (the email must carry a
# passing DKIM signature from one of them) and turns a matching message into an
# EmailAlert::ParsedAlert. #parse returns nil for mail from the institution that
# is not a transaction alert (OTPs, login notices, marketing).
class EmailAlert::Parsers::Base
  CURRENCY_SYMBOLS = { "₦" => "NGN", "$" => "USD", "£" => "GBP", "€" => "EUR" }.freeze
  COLONS = [ ":", "：" ].freeze

  class << self
    attr_reader :key, :institution_name, :domains, :timezone

    def configure(key:, institution_name:, domains:, timezone: "UTC")
      @key = key
      @institution_name = institution_name
      @domains = domains
      @timezone = timezone
    end

    def handles_domain?(domain)
      domain = domain.to_s.downcase
      domains.any? { |d| domain == d || domain.end_with?(".#{d}") }
    end
  end

  attr_reader :message

  def initialize(message)
    @message = message
  end

  def parse
    raise NotImplementedError
  end

  private

    def lines
      message.lines
    end

    def text
      message.text
    end

    def labels
      []
    end

    # The value for +label+: from the HTML table row when the template uses
    # one, otherwise from the flattened lines, where the label, an optional
    # colon and the value are consecutive lines (or "Label: value" on one).
    # Returns nil for an empty field.
    def value_for(label)
      fields = message.table_fields
      return fields[label.downcase].presence if fields.key?(label.downcase)

      pattern = /\A#{Regexp.escape(label)}\s*[:：]?\s*(.*)\z/i
      lines.each_with_index do |line, index|
        match = line.match(pattern)
        next unless match

        inline = match[1].strip
        return inline if inline.present? && !COLONS.include?(inline)

        following = lines[(index + 1)..].to_a.drop_while { |l| COLONS.include?(l) }.first
        return nil if following.nil? || label_line?(following)
        return following
      end
      nil
    end

    def label_line?(line)
      normalized = line.sub(/[:：]\s*\z/, "").strip.downcase
      labels.any? { |label| label.downcase == normalized }
    end

    # The first line after the line matching +pattern+.
    def line_after(pattern)
      index = lines.index { |line| line.match?(pattern) }
      index && lines[index + 1]
    end

    # Parses "NGN 250000", "₦1,500.00", "$9.45", "50 USDT" into [BigDecimal, currency].
    def parse_money(value, default_currency: nil)
      return nil if value.blank?

      str = value.strip
      currency = CURRENCY_SYMBOLS.find { |symbol, _| str.include?(symbol) }&.last
      currency ||= str[/\b([A-Z]{3,4})\b/, 1]
      currency ||= default_currency
      number = str[/-?\d[\d,]*(?:\.\d+)?/]
      return nil if number.nil? || currency.nil?

      [ BigDecimal(number.delete(",")), currency ]
    rescue ArgumentError
      nil
    end

    def parse_time(value, format)
      return nil if value.blank?

      ActiveSupport::TimeZone[self.class.timezone].strptime(value.strip, format)
    rescue ArgumentError
      nil
    end

    def build(**attrs)
      EmailAlert::ParsedAlert.new(
        parser_key: self.class.key,
        institution_name: self.class.institution_name,
        **attrs
      )
    end
end
