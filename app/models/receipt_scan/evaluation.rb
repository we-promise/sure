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

  # user: the member whose AI switch the receipts are read under, as an upload would be.
  def initialize(dir:, family:, user:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @dir = Pathname(dir)
    @family = family
    @user = user
    @clock = clock
  end

  REPORT = "report".freeze

  def run
    raise ArgumentError, "No AI model that reads images is routed for receipts" unless ReceiptScan.extraction_available?(family:, user:)
    # The report is written to report.json, which would overwrite that receipt's expected values.
    raise ArgumentError, "Rename the receipt called #{REPORT}: the report is written to #{REPORT}.json" if receipts.any? { _1.first == REPORT }

    results = receipts.map { |name, path, expected| evaluate(name, path, expected) }
    report = {
      "count" => results.size,
      "accuracy" => FIELDS.index_with { |field| accuracy(results, field) },
      "flag_rate" => ratio(results.count { _1["flags"].any? }, results.size),
      "mean_latency_seconds" => results.empty? ? 0.0 : (results.sum { _1["latency_seconds"] } / results.size).round(2),
      "results" => results
    }
    File.write(dir.join("#{REPORT}.json"), JSON.pretty_generate(report))
    report
  end

  private
    attr_reader :dir, :family, :user, :clock

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
      result = begin
        file = File.open(path, "rb") do |io|
          ReceiptScan::ImageNormalizer.call(io:, content_type: CONTENT_TYPES.fetch(path.extname.downcase), filename: path.basename.to_s)
        end
        files = [ Ai::Attachment.new(filename: file[:filename], content_type: file[:content_type], data: file[:io].read) ]
        # The lane an upload's job reads in.
        Ai::Sequencer.with_lane(:prompt) do
          Ai::Generations::ExtractReceipt.new(files:, category_names: family.categories.pluck(:name), family:, user:).call
        end
      rescue ReceiptScan::ImageNormalizer::UnsupportedFile => error
        Ai::Result.failure(error)
      end
      latency = (clock.call - started).round(2)

      unless result.success?
        # Wrong on every field it was expected to read.
        scores = FIELDS.select { expected[_1].present? }.index_with(false)
        message = result.error&.message || result.availability&.reason.to_s
        return { "name" => name, "error" => message, "scores" => scores, "flags" => [], "latency_seconds" => latency }
      end

      extraction = ReceiptScan::Extraction.from_ai(result.value)
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
      when "total" then extraction.total.present? && extraction.total == ReceiptScan::Extraction.decimal(expected)
      when "currency" then extraction.currency == expected.to_s.upcase
      when "nip" then extraction.nip.to_s == expected.to_s.gsub(/\D/, "")
      end
    end

    # Share of receipts with an expected value for the field that got it right; a failed
    # extraction counts as wrong.
    def accuracy(results, field)
      graded = results.select { _1["scores"].key?(field) }
      ratio(graded.count { _1["scores"][field] }, graded.size)
    end

    def ratio(numerator, denominator)
      denominator.zero? ? 0.0 : (numerator.to_f / denominator).round(4)
    end
end
