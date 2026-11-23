# Measures receipt extraction against a folder of receipts whose correct values are known, so a
# model or prompt change can be judged on real receipts before it ships. The folder holds
# NAME.jpg|png|webp|heic|pdf next to NAME.json with the expected merchant, date, total, currency
# and optionally nip. Never commit such a folder: receipts carry personal data.
class ReceiptScan::Evaluation
  FIELDS = %w[merchant date total currency nip].freeze
  CONTENT_TYPES = {
    ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".png" => "image/png", ".webp" => "image/webp",
    ".heic" => "image/heic", ".heif" => "image/heif", ".pdf" => "application/pdf"
  }.freeze

  ExpectedAccount = Struct.new(:currency)

  def initialize(dir:, family:, provider: Provider::Registry.preferred_llm_provider, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @dir = Pathname(dir)
    @family = family
    @provider = provider
    @clock = clock
  end

  def run
    raise ArgumentError, "No receipt-capable AI provider is configured" unless provider&.supports_receipt_extraction?

    results = receipts.map { |name, path, expected| evaluate(name, path, expected) }
    report = {
      "count" => results.size,
      "accuracy" => FIELDS.index_with { |field| accuracy(results, field) },
      "flag_rate" => ratio(results.count { _1["flags"].any? }, results.size),
      "mean_latency_seconds" => results.empty? ? 0.0 : (results.sum { _1["latency_seconds"] } / results.size).round(2),
      "results" => results
    }
    File.write(dir.join("report.json"), JSON.pretty_generate(report))
    report
  end

  private
    attr_reader :dir, :family, :provider, :clock

    def receipts
      dir.children.sort.filter_map do |path|
        next unless CONTENT_TYPES.key?(path.extname.downcase)

        expected_path = path.sub_ext(".json")
        next unless expected_path.exist?

        [ path.basename(path.extname).to_s, path, JSON.parse(expected_path.read) ]
      end
    end

    def evaluate(name, path, expected)
      started = clock.call
      file = File.open(path, "rb") do |io|
        ReceiptScan::ImageNormalizer.call(io:, content_type: CONTENT_TYPES.fetch(path.extname.downcase), filename: path.basename.to_s)
      end
      response = provider.extract_receipt(
        files: [ { data: file[:io].read, content_type: file[:content_type] } ],
        category_names: family.categories.pluck(:name),
        family:
      )
      latency = (clock.call - started).round(2)

      unless response.success?
        return { "name" => name, "error" => response.error&.message, "scores" => {}, "flags" => [], "latency_seconds" => latency }
      end

      extraction = response.data
      flags = ReceiptScan::Validator.new(extraction, account: ExpectedAccount.new(expected["currency"])).problems.map { _1["reason"] }
      { "name" => name, "scores" => scores(extraction, expected), "flags" => flags, "latency_seconds" => latency }
    end

    def scores(extraction, expected)
      FIELDS.each_with_object({}) do |field, scores|
        next if expected[field].blank?

        scores[field] = correct?(field, extraction, expected[field])
      end
    end

    def correct?(field, extraction, expected)
      case field
      when "merchant" then extraction.merchant.to_s.downcase.include?(expected.to_s.downcase)
      when "date" then extraction.date&.iso8601 == expected.to_s
      when "total" then extraction.total.present? && extraction.total == BigDecimal(expected.to_s)
      when "currency" then extraction.currency == expected.to_s.upcase
      when "nip" then extraction.nip.to_s == expected.to_s.gsub(/\D/, "")
      end
    end

    # Share of receipts with an expected value for the field that got it right; a failed
    # extraction counts as wrong.
    def accuracy(results, field)
      graded = results.select { _1["scores"].key?(field) || (_1["error"] && field != "nip") }
      ratio(graded.count { _1["scores"][field] }, graded.size)
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end
end
