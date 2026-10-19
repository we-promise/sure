# Reads the itemized lines off a receipt so a transaction can be split by
# them. Text PDFs (most emailed retailer receipts) are sent as extracted text,
# which works with any model; photos and scanned PDFs (rendered to page
# images) are sent to the vision endpoint.
class Provider::Openai::ReceiptExtractor
  include Provider::Openai::Concerns::UsageRecorder
  include Provider::Openai::Concerns::JsonMode
  include Provider::Openai::Concerns::PdfPageRenderer

  IMAGE_CONTENT_TYPES = %w[image/jpeg image/jpg image/png image/gif image/webp].freeze
  MAX_TEXT_CHARS = 30_000
  MAX_PDF_PAGES = 5

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
        extract_from_pdf
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

    # A PDF without a text layer (a scanned or photographed receipt) is
    # rendered to page images, the same fallback the PDF import path uses.
    def extract_from_pdf
      text = Pdf::TextExtractor.pages(file_content).join("\n\n")
      text.present? ? extract_from_text(text) : extract_from_pdf_images
    end

    def extract_from_text(text)
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
      vision_request([ "data:#{content_type};base64,#{Base64.strict_encode64(file_content)}" ])
    end

    def extract_from_pdf_images
      pages = render_pdf_pages(file_content)
      raise Provider::Openai::Error, "Could not read text or page images from the receipt PDF" if pages.empty?

      vision_request(pages.first(MAX_PDF_PAGES).map { |page| "data:image/png;base64,#{page}" }, pages: pages.size)
    end

    def vision_request(image_urls, pages: nil)
      content = image_urls.map { |url| { type: "image_url", image_url: { url: url } } }
      content << { type: "text", text: "Read this receipt and respond with valid JSON only." }

      params = {
        model: model,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: content }
        ]
      }
      # Not every OpenAI-compatible vision endpoint accepts response_format
      # alongside images (the PDF vision path omits it for the same reason).
      apply_response_limit(params)

      request(params, operation: "extract_receipt_vision", metadata: { pages: pages }.compact)
    end

    def apply_response_limit(params)
      return if max_response_tokens.blank?

      if Provider::Openai.native_pdf_completion_limit?(model: model, custom_provider: custom_provider)
        params[:max_completion_tokens] = max_response_tokens
      else
        params[:max_tokens] = max_response_tokens
      end
    end

    def request(params, operation:, metadata: {})
      response = client.chat(parameters: params)

      record_usage(model, response.dig("usage"), operation: operation, metadata: { content_type: content_type, **metadata })

      ReceiptExtraction.from_response(parse_json_flexibly(response.dig("choices", 0, "message", "content")))
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
