class Provider::Openai::BrokerageStatementExtractor
  MAX_CHARS_PER_CHUNK = 3000
  attr_reader :client, :pdf_content, :model

  def initialize(client:, pdf_content:, model:)
    @client = client
    @pdf_content = pdf_content
    @model = model
  end

  def extract
    pages = extract_pages_from_pdf
    raise Provider::Openai::Error, "Could not extract text from PDF" if pages.empty?

    chunks = build_chunks(pages)
    Rails.logger.info("BrokerageStatementExtractor: Processing #{chunks.size} chunk(s) from #{pages.size} page(s)")

    all_trades = []
    metadata = {}

    chunks.each_with_index do |chunk, index|
      Rails.logger.info("BrokerageStatementExtractor: Processing chunk #{index + 1}/#{chunks.size}")
      result = process_chunk(chunk)

      tagged_trades = (result[:trades] || []).map { |t| t.merge(chunk_index: index) }
      all_trades.concat(tagged_trades)

      merge_metadata!(metadata, result)
    end

    {
      trades: deduplicate_trades(all_trades),
      period: metadata[:period] || {},
      broker_name: metadata[:broker_name],
      account_holder: metadata[:account_holder],
      account_number: metadata[:account_number],
      currency: metadata[:currency],
      cash_balance: metadata[:cash_balance],
      total_value: metadata[:total_value],
      as_of_date: metadata[:as_of_date]
    }
  end

  private

    def extract_pages_from_pdf
      return [] if pdf_content.blank?

      reader = PDF::Reader.new(StringIO.new(pdf_content))
      reader.pages.map(&:text).reject(&:blank?)
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
      Rails.logger.error("Failed to extract text from PDF: #{e.message}")
      []
    end

    def build_chunks(pages)
      chunks = []
      current_chunk = []
      current_size = 0

      pages.each do |page_text|
        if page_text.length > MAX_CHARS_PER_CHUNK
          chunks << current_chunk.join("\n\n") if current_chunk.any?
          current_chunk = []
          current_size = 0
          split_oversized_page(page_text).each { |piece| chunks << piece }
          next
        end

        if current_size + page_text.length > MAX_CHARS_PER_CHUNK && current_chunk.any?
          chunks << current_chunk.join("\n\n")
          current_chunk = []
          current_size = 0
        end

        current_chunk << page_text
        current_size += page_text.length
      end

      chunks << current_chunk.join("\n\n") if current_chunk.any?
      chunks
    end

    def split_oversized_page(text)
      pieces = []
      offset = 0
      while offset < text.length
        pieces << text[offset, MAX_CHARS_PER_CHUNK]
        offset += MAX_CHARS_PER_CHUNK
      end
      pieces
    end

    def process_chunk(text)
      params = {
        model: model,
        messages: [
          { role: "system", content: instructions_with_metadata },
          { role: "user", content: "Extract trades and any account summary fields visible in this brokerage statement excerpt:\n\n#{text}" }
        ],
        response_format: { type: "json_object" }
      }

      response = client.chat(parameters: params)
      content = response.dig("choices", 0, "message", "content")

      raise Provider::Openai::Error, "No response from AI" if content.blank?

      parsed = parse_json_response(content)

      {
        trades: normalize_trades(parsed["trades"] || []),
        period: {
          start_date: parsed.dig("statement_period", "start_date"),
          end_date: parsed.dig("statement_period", "end_date")
        },
        broker_name: parsed["broker_name"],
        account_holder: parsed["account_holder"],
        account_number: parsed["account_number"],
        currency: parsed["currency"],
        cash_balance: parse_amount(parsed["cash_balance"]),
        total_value: parse_amount(parsed["total_value"]),
        as_of_date: parse_date(parsed["as_of_date"])
      }
    end

    def parse_json_response(content)
      cleaned = content.gsub(%r{^```json\s*}i, "").gsub(/```\s*$/, "").strip
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      Rails.logger.error("BrokerageStatementExtractor JSON parse error: #{e.message} (content_length=#{content.to_s.bytesize})")
      { "trades" => [] }
    end

    def deduplicate_trades(trades)
      seen_strong = Set.new
      weak_by_chunk = Hash.new { |h, k| h[k] = Set.new }

      trades.select do |t|
        chunk = t[:chunk_index]
        if strong_discriminator?(t)
          key = strong_identity(t)
          next false if seen_strong.include?(key)

          seen_strong << key
          true
        else
          key = weak_identity(t)
          next false if weak_by_chunk[chunk].include?(key)

          weak_by_chunk[chunk] << key
          true
        end
      end.map { |t| t.except(:chunk_index) }
    end

    def strong_discriminator?(t)
      t[:order_id].present? || t[:execution_time].present? || t[:row_signature].present?
    end

    def strong_identity(t)
      [
        t[:date], t[:ticker], t[:qty], t[:price], t[:fees],
        t[:order_id].to_s, t[:execution_time].to_s, t[:row_signature].to_s
      ]
    end

    def weak_identity(t)
      [ t[:date], t[:ticker], t[:qty], t[:price], t[:fees], t[:name].to_s.strip ]
    end

    def normalize_trades(trades)
      trades.filter_map do |trade|
        date = parse_date(trade["date"] || trade["close_time"] || trade["open_time"])
        ticker = (trade["ticker"] || trade["symbol"])&.strip&.upcase
        next if ticker.blank?

        qty = parse_quantity(trade["quantity"] || trade["qty"] || trade["volume"])
        price = parse_amount(trade["price"] || trade["unit_price"] || trade["open_price"] || trade["close_price"])
        next if qty.nil? || price.nil?

        action = (trade["action"] || trade["type"] || trade["side"])&.strip&.downcase
        signed_qty = apply_action_to_qty(action, qty)
        name = trade["security"] || trade["name"] || trade["description"]

        {
          date: date,
          ticker: ticker,
          name: name,
          qty: signed_qty,
          price: price,
          currency: (trade["currency"])&.strip&.upcase,
          exchange_operating_mic: trade["exchange"]&.strip&.upcase,
          fees: parse_amount(trade["fees"] || trade["commission"]),
          order_id: trade_string_field(trade, "order_id", "order_confirmation", "confirmation_number", "reference", "transaction_id"),
          execution_time: trade_string_field(trade, "execution_time", "execution_time_utc", "time", "exec_time", "trade_time"),
          row_signature: trade_string_field(trade, "row_signature", "row_id", "line_id")
        }
      end
    end

    def trade_string_field(trade, *keys)
      keys.flatten.each do |key|
        v = trade[key]
        next if v.nil?

        s = v.to_s.strip
        return s if s.present?
      end
      nil
    end

    def apply_action_to_qty(action, qty)
      return qty if action.nil?

      case action
      when "sell", "sold", "s"
        -qty.abs
      else
        qty.abs
      end
    end

    def parse_date(date_str)
      return nil if date_str.blank?

      Date.parse(date_str).strftime("%Y-%m-%d")
    rescue ArgumentError
      nil
    end

    def parse_amount(amount)
      return nil if amount.nil?

      if amount.is_a?(Numeric)
        amount.to_f
      else
        str = amount.to_s
        # Handle European format: 1.234,56 -> 1234.56
        if str.match?(/\d+\.\d{3},\d{1,2}$/)
          str = str.tr(".", "").tr(",", ".")
        elsif str.match?(/,\d{1,2}$/) && !str.include?(".")
          str = str.tr(",", ".")
        end
        cleaned = str.gsub(/[^0-9.\-]/, "")
      end
      return nil if cleaned.blank?
      cleaned.to_f
    end

    def parse_quantity(qty)
      return nil if qty.nil?

      if qty.is_a?(Numeric)
        qty.to_f
      else
        cleaned = qty.to_s.gsub(/[^0-9.\-]/, "")
        return nil if cleaned.blank?
        cleaned.to_f
      end
    end

    def instructions_with_metadata
      <<~INSTRUCTIONS.strip
        Extract brokerage/investment statement data as JSON. Return:
        {"broker_name":"...","account_holder":"...","account_number":"last 4 digits","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"currency":"USD","cash_balance":null,"total_value":null,"as_of_date":null,"trades":[{"date":"YYYY-MM-DD","action":"buy","ticker":"AAPL","security":"Apple Inc.","quantity":10,"price":175.50,"fees":0.00,"currency":"USD","order_id":null,"execution_time":null}]}

        Rules:
        - action must be "buy" or "sell"
        - ticker should be the stock/ETF/fund ticker symbol (e.g. AAPL, MSFT, VOO)
        - quantity is always positive; the action field indicates buy vs sell
        - price is the per-share/per-unit price
        - fees/commission should be extracted if visible, otherwise 0.00
        - Include order_id, execution_time (time of fill), confirmation/reference, or row identifiers when the statement shows them; use null when absent
        - Dates as YYYY-MM-DD
        - Extract ALL trades visible in the statement
        - Include dividend reinvestments as "buy" trades if present
        - For "closed position" reports (e.g. XTB), each row is a round-trip trade. Extract as TWO trades: a "buy" at open_price on open_time and a "sell" at close_price on close_time, both with the same ticker and volume
        - For "order history" or "trade confirmation" reports, extract each order as a single trade
        - If cash_balance, total_value, or as_of_date are visible in this excerpt, include them; use null for fields not shown on this page
        - JSON only, no markdown
      INSTRUCTIONS
    end

    def merge_metadata!(metadata, result)
      %i[broker_name account_holder account_number currency].each do |key|
        val = result[key]
        next unless merge_scalar_present?(val)
        metadata[key] = val if metadata[key].blank?
      end

      %i[cash_balance total_value as_of_date].each do |key|
        val = result[key]
        next if val.nil?
        next if val.is_a?(String) && val.strip.empty?
        metadata[key] = val
      end

      period = result[:period]
      return unless period.is_a?(Hash)

      metadata[:period] ||= {}
      if period[:start_date].present?
        metadata[:period][:start_date] ||= period[:start_date]
      end
      metadata[:period][:end_date] = period[:end_date] if period[:end_date].present?
    end

    def merge_scalar_present?(val)
      return false if val.nil?
      return false if val.is_a?(String) && val.strip.empty?
      true
    end
end
