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
      result = process_chunk(chunk, index == 0)

      tagged_trades = (result[:trades] || []).map { |t| t.merge(chunk_index: index) }
      all_trades.concat(tagged_trades)

      if index == 0
        metadata = {
          broker_name: result[:broker_name],
          account_holder: result[:account_holder],
          account_number: result[:account_number],
          period: result[:period],
          currency: result[:currency],
          cash_balance: result[:cash_balance],
          total_value: result[:total_value],
          as_of_date: result[:as_of_date]
        }
      end

      if result.dig(:period, :end_date).present?
        metadata[:period] ||= {}
        metadata[:period][:end_date] = result.dig(:period, :end_date)
      end
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
    rescue => e
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
          chunks << page_text
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

    def process_chunk(text, is_first_chunk)
      params = {
        model: model,
        messages: [
          { role: "system", content: is_first_chunk ? instructions_with_metadata : instructions_trades_only },
          { role: "user", content: "Extract trades from this brokerage statement:\n\n#{text}" }
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
      seen = Set.new
      trades.select do |t|
        key = [ t[:date], t[:ticker], t[:qty], t[:price], t[:chunk_index] ]

        duplicate = seen.any? do |prev_key|
          prev_key[0..3] == key[0..3] && (prev_key[4] - key[4]).abs <= 1
        end

        seen << key
        !duplicate
      end.map { |t| t.except(:chunk_index) }
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

        {
          date: date,
          ticker: ticker,
          name: trade["security"] || trade["name"] || trade["description"],
          qty: signed_qty,
          price: price,
          currency: (trade["currency"])&.strip&.upcase,
          exchange_operating_mic: trade["exchange"]&.strip&.upcase,
          fees: parse_amount(trade["fees"] || trade["commission"])
        }
      end
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
        cleaned = amount.to_s.gsub(/[^0-9.\-]/, "")
        return nil if cleaned.blank?
        cleaned.to_f
      end
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
        {"broker_name":"...","account_holder":"...","account_number":"last 4 digits","statement_period":{"start_date":"YYYY-MM-DD","end_date":"YYYY-MM-DD"},"currency":"USD","cash_balance":null,"total_value":null,"as_of_date":null,"trades":[{"date":"YYYY-MM-DD","action":"buy","ticker":"AAPL","security":"Apple Inc.","quantity":10,"price":175.50,"fees":0.00,"currency":"USD"}]}

        Rules:
        - action must be "buy" or "sell"
        - ticker should be the stock/ETF/fund ticker symbol (e.g. AAPL, MSFT, VOO)
        - quantity is always positive; the action field indicates buy vs sell
        - price is the per-share/per-unit price
        - fees/commission should be extracted if visible, otherwise 0.00
        - Dates as YYYY-MM-DD
        - Extract ALL trades visible in the statement
        - Include dividend reinvestments as "buy" trades if present
        - For "closed position" reports (e.g. XTB), each row is a round-trip trade. Extract as TWO trades: a "buy" at open_price on open_time and a "sell" at close_price on close_time, both with the same ticker and volume
        - For "order history" or "trade confirmation" reports, extract each order as a single trade
        - If cash_balance, total_value, or as_of_date are visible, include them
        - JSON only, no markdown
      INSTRUCTIONS
    end

    def instructions_trades_only
      <<~INSTRUCTIONS.strip
        Extract trades from brokerage statement text as JSON. Return:
        {"trades":[{"date":"YYYY-MM-DD","action":"buy","ticker":"AAPL","security":"Apple Inc.","quantity":10,"price":175.50,"fees":0.00,"currency":"USD"}]}

        Rules:
        - action must be "buy" or "sell"
        - ticker should be the stock/ETF/fund ticker symbol
        - quantity is always positive; the action field indicates buy vs sell
        - price is the per-share/per-unit price
        - fees/commission should be extracted if visible, otherwise 0.00
        - Dates as YYYY-MM-DD
        - Extract ALL trades
        - For "closed position" rows, extract TWO trades: a "buy" at open_price/open_time and a "sell" at close_price/close_time
        - JSON only, no markdown
      INSTRUCTIONS
    end
end
