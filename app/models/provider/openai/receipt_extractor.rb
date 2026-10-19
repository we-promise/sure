# Reads the itemized lines off a receipt so a transaction can be split by
# them. Text PDFs (most emailed retailer receipts) are sent as extracted text,
# which works with any model; photos are sent to the vision endpoint.
class Provider::Openai::ReceiptExtractor
  include Provider::Openai::Concerns::UsageRecorder
  include Provider::Openai::Concerns::JsonMode

  IMAGE_CONTENT_TYPES = %w[image/jpeg image/jpg image/png image/gif image/webp].freeze
  MAX_TEXT_CHARS = 30_000

  attr_reader :client, :model, :file_content, :content_type, :custom_provider, :langfuse_trace, :family,
              :max_response_tokens, :json_mode

  def initialize(client, model:, file_content:, content_type:, custom_provider: false, langfuse_trace: nil,
                 family: nil, max_response_tokens: nil, json_mode: nil)
    @client = client
    @model = model
    @file_content = file_content
    @content_type = content_type
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
    @max_response_tokens = max_response_tokens
    @json_mode = json_mode || default_json_mode
  end

  def extract
    span = langfuse_trace&.span(name: "extract_receipt_api_call", input: {
      model: model, content_type: content_type, size: file_content&.bytesize
    })

    result =
      if content_type == "application/pdf"
        extract_from_text
      elsif IMAGE_CONTENT_TYPES.include?(content_type)
        extract_from_image
      else
        raise Provider::Openai::Error, "Unsupported receipt type: #{content_type}"
      end

    span&.end(output: { line_item_count: result.line_items.size })
    result
  rescue => e
    span&.end(output: { error: e.message, error_detail: safe_error_detail(e) }, level: "ERROR")
    raise
  end

  def instructions
    <<~INSTRUCTIONS.strip
      You read store receipts and invoices and list what was bought.

      Return every purchased line item with its name and its line total as printed
      (quantity times unit price when both are shown). Do not include subtotal,
      tax, tip, discount, payment, change or balance lines as items.

      Also return, when the receipt shows them:
      - tax: the total tax charged
      - discount: the total of receipt-level discounts and coupons as a positive
        number (a discount printed against one item reduces that item's line total
        instead)
      - total: the amount actually charged
      - merchant_name and currency (ISO 4217 code)

      Use plain numbers without currency symbols. Use null for anything the receipt
      does not show. Do not guess values you cannot read.

      Respond with ONLY valid JSON in this exact format (no markdown, no other text):
      {
        "merchant_name": "string or null",
        "currency": "USD or null",
        "line_items": [ { "name": "string", "amount": 0.0 } ],
        "tax": 0.0,
        "discount": 0.0,
        "total": 0.0
      }
    INSTRUCTIONS
  end

  private

    ReceiptExtraction = Provider::LlmConcept::ReceiptExtraction
    ReceiptLineItem = Provider::LlmConcept::ReceiptLineItem

    def extract_from_text
      text = Pdf::TextExtractor.pages(file_content).join("\n\n")
      raise Provider::Openai::Error, "Could not read text from the receipt PDF" if text.blank?

      params = {
        model: model,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: "Receipt text:\n\n#{text.truncate(MAX_TEXT_CHARS)}" }
        ]
      }
      apply_json_mode(params, mode: json_mode)
      apply_response_limit(params)

      request(params, operation: "extract_receipt")
    end

    def extract_from_image
      params = {
        model: model,
        messages: [
          { role: "system", content: instructions },
          {
            role: "user",
            content: [
              { type: "image_url", image_url: { url: "data:#{content_type};base64,#{Base64.strict_encode64(file_content)}" } },
              { type: "text", text: "Read this receipt and respond with valid JSON only." }
            ]
          }
        ]
      }
      # Not every OpenAI-compatible vision endpoint accepts response_format
      # alongside images (the PDF vision path omits it for the same reason).
      apply_response_limit(params)

      request(params, operation: "extract_receipt_vision")
    end

    def apply_response_limit(params)
      return if max_response_tokens.blank?

      if Provider::Openai.native_pdf_completion_limit?(model: model, custom_provider: custom_provider)
        params[:max_completion_tokens] = max_response_tokens
      else
        params[:max_tokens] = max_response_tokens
      end
    end

    def request(params, operation:)
      response = client.chat(parameters: params)

      record_usage(model, response.dig("usage"), operation: operation, metadata: { content_type: content_type })

      build_result(parse_json_flexibly(response.dig("choices", 0, "message", "content")))
    end

    def build_result(parsed)
      line_items = Array(parsed["line_items"]).filter_map do |item|
        next unless item.is_a?(Hash)

        amount = to_decimal(item["amount"])
        name = item["name"].to_s.strip
        next if amount.nil? || name.blank?

        ReceiptLineItem.new(name: name.truncate(255), amount: amount)
      end

      ReceiptExtraction.new(
        merchant_name: parsed["merchant_name"].presence,
        currency: parsed["currency"].presence&.to_s&.upcase,
        line_items: line_items,
        tax: to_decimal(parsed["tax"]),
        discount: to_decimal(parsed["discount"])&.abs,
        total: to_decimal(parsed["total"])
      )
    end

    def to_decimal(value)
      return nil if value.nil? || value.to_s.strip.empty?

      decimal = BigDecimal(value.to_s.strip)
      decimal.finite? ? decimal : nil
    rescue ArgumentError, TypeError
      nil
    end

    def parse_json_flexibly(raw)
      return {} if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      if raw =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Continue to next strategy
        end
      end

      if raw =~ /(\{[\s\S]*\})/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Fall through to error
        end
      end

      raise Provider::Openai::Error, "Could not parse JSON from receipt extraction response: #{raw.truncate(200)}"
    end
end
