module Provider::LlmConcept
  extend ActiveSupport::Concern

  # Items per LLM call for AI rule jobs and evals: ENV > Setting > 25.
  def self.max_items_per_call
    [ ENV["LLM_MAX_ITEMS_PER_CALL"], Setting.llm_max_items_per_call, 25 ].map(&:to_i).find(&:positive?)
  end

  AutoCategorization = Data.define(:transaction_id, :category_name)

  def auto_categorize(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_categorize"
  end

  AutoDetectedMerchant = Data.define(:transaction_id, :business_name, :business_url)

  def auto_detect_merchants(transactions)
    raise NotImplementedError, "Subclasses must implement #auto_detect_merchants"
  end

  EnhancedMerchant = Data.define(:merchant_id, :business_url)

  def enhance_provider_merchants(merchants)
    raise NotImplementedError, "Subclasses must implement #enhance_provider_merchants"
  end

  # One proposed recurring-bill configuration, inferred from charge history.
  # Every field is nullable: null means the history cannot support a value
  # (or, in configure mode, that the current configuration is already right).
  BillSetupSuggestion = Data.define(
    :name, :amount, :frequency, :day_of_month, :weekday, :month_of_year,
    :category_name, :bill_type, :autopay, :confidence, :rationale
  )

  def suggest_bill_setup(charges:, categories: [], current_config: nil, model: "", family: nil)
    raise NotImplementedError, "Subclasses must implement #suggest_bill_setup"
  end

  PdfProcessingResult = Data.define(:summary, :document_type, :extracted_data)

  def supports_pdf_processing?
    false
  end

  def process_pdf(pdf_content:, family: nil)
    raise NotImplementedError, "Provider does not support PDF processing"
  end

  # One printed line of a receipt. `amount` is the line total as printed,
  # before receipt-level tax and discounts.
  ReceiptLineItem = Data.define(:name, :amount)
  # `tax` and `discount` are receipt-level totals as positive numbers; any of
  # the numeric fields is nil when the receipt does not show it.
  ReceiptExtraction = Data.define(:merchant_name, :currency, :line_items, :tax, :discount, :total) do
    # Builds an extraction from the model's JSON (string or symbol keys),
    # dropping lines without a name or a readable amount.
    def self.from_response(parsed)
      parsed = parsed.to_h.with_indifferent_access

      line_items = Array(parsed[:line_items]).filter_map do |item|
        next unless item.respond_to?(:to_h)

        item = item.to_h.with_indifferent_access
        amount = decimal_or_nil(item[:amount])
        name = item[:name].to_s.strip
        next if amount.nil? || name.blank?

        ReceiptLineItem.new(name: name.truncate(255), amount: amount)
      end

      new(
        merchant_name: parsed[:merchant_name].presence,
        currency: parsed[:currency].presence&.to_s&.upcase,
        line_items: line_items,
        tax: decimal_or_nil(parsed[:tax]),
        discount: decimal_or_nil(parsed[:discount])&.abs,
        total: decimal_or_nil(parsed[:total])
      )
    end

    def self.decimal_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      decimal = BigDecimal(value.to_s.strip)
      decimal.finite? ? decimal : nil
    rescue ArgumentError, TypeError
      nil
    end
  end

  # @param content_type [String, nil] the receipt's MIME type; nil asks whether
  #   any receipt can be read
  def supports_receipt_extraction?(content_type: nil)
    false
  end

  def extract_receipt(file_content:, content_type:, family: nil)
    raise NotImplementedError, "Provider does not support receipt extraction"
  end

  ChatMessage = Data.define(:id, :output_text)
  ChatStreamChunk = Data.define(:type, :data, :usage)
  ChatResponse = Data.define(:id, :model, :messages, :function_requests)
  ChatFunctionRequest = Data.define(:id, :call_id, :function_name, :function_args, :extra_content) do
    def initialize(id:, call_id:, function_name:, function_args:, extra_content: nil)
      super
    end
  end

  def chat_response(
    prompt,
    model:,
    instructions: nil,
    functions: [],
    function_results: [],
    tool_choice: nil,
    messages: nil,
    conversation_history: [],
    streamer: nil,
    previous_response_id: nil,
    session_id: nil,
    user_identifier: nil
  )
    raise NotImplementedError, "Subclasses must implement #chat_response"
  end
end
