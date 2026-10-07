class Import::DateParser
  Parsed = Data.define(:date, :timestamp)
  Detection = Data.define(:formats) do
    def status
      return :unsupported if formats.empty?
      return :ambiguous if formats.many? || formats.first.include?("%y")

      :detected
    end

    def format
      formats.first if status == :detected
    end
  end

  def self.parse(value, format:, strict: true)
    text = value.to_s.strip
    if format == "iso8601"
      timestamp = Entry::Timestamp.parse(text)
      return Parsed.new(date: timestamp.to_date, timestamp: timestamp)
    end

    if strict
      parts = Date._strptime(text, format)
      complete = parts && parts[:leftover].blank? && parts.values_at(:year, :mon, :mday).all?
      complete &&= parts[:year] >= 1000 unless format.include?("%y")
      raise ArgumentError, "Date must match the entire format" unless complete
    end

    Parsed.new(date: Date.strptime(text, format), timestamp: nil)
  end

  # Both the conservative CSV detector and the legacy best-match detector use
  # this candidate evaluation. Only their selection policies differ.
  def self.score(samples, formats:, strict:)
    reasonable_range = Import.reasonable_date_range
    formats.map do |format|
      parsed_count = 0
      reasonable_count = 0
      samples.each do |sample|
        begin
          date = parse(sample, format: format, strict: strict).date
          parsed_count += 1
          reasonable_count += 1 if reasonable_range.cover?(date)
        rescue Date::Error, ArgumentError
          next
        end
      end
      { format: format, parsed: parsed_count, reasonable: reasonable_count }
    end
  end

  def self.detect(samples)
    values = Array(samples).map { |value| value.to_s.strip }.reject(&:blank?).uniq
    return Detection.new(formats: []) if values.empty?

    formats = (Family::DATE_FORMATS + Import::CSV_ONLY_DATE_FORMATS).map(&:last) + [ "iso8601" ]
    # %e and %d accept the same day values; this is not day/month ambiguity.
    formats = formats.uniq { |format| format.gsub("%e", "%d") }
    matches = score(values, formats: formats, strict: true)
      .select { |candidate| candidate[:parsed] == values.size }
      .pluck(:format)
    Detection.new(formats: matches)
  end
end
