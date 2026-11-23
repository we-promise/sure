# Reads a photographed or uploaded receipt, bill or invoice with Claude's vision and returns its
# fields as a ReceiptExtraction. Line items come back assigned to the family's own categories so
# the receipt can be split without a second call.
class Provider::Anthropic::ReceiptExtractor
  include Provider::Anthropic::Concerns::UsageRecorder
  include Provider::Anthropic::Concerns::StructuredOutput

  TOOL_NAME = "report_receipt".freeze
  OPERATION = "extract_receipt".freeze
  # Same request budget as PdfProcessor: files travel base64-encoded (~4/3 larger) inside a
  # 32 MB request body next to the prompt and schema.
  MAX_FILES_BYTES = Provider::Anthropic::PdfProcessor::MAX_PDF_BYTES
  DOCUMENT_KINDS = %w[receipt invoice other].freeze
  PAYMENT_METHODS = %w[card cash mixed unknown].freeze

  attr_reader :client, :model, :files, :category_names, :langfuse_trace, :family

  def initialize(client, model:, files:, category_names:, langfuse_trace: nil, family: nil)
    @client = client
    @model = model
    @files = files
    @category_names = category_names
    @langfuse_trace = langfuse_trace
    @family = family
  end

  def extract
    raise Provider::Anthropic::Error, "Receipt files are required" if files.blank?
    if total_bytes > MAX_FILES_BYTES
      raise Provider::Anthropic::Error,
            "Receipt files are too large (#{total_bytes} bytes); base64-encoded they would exceed Anthropic's 32 MB request limit"
    end

    span = langfuse_trace&.generation(name: "extract_receipt_api_call", model:, input: { model:, files: files.size, bytes: total_bytes })

    response = create_structured_message(
      tool_name: TOOL_NAME,
      operation: OPERATION,
      model:,
      max_tokens:,
      system_: Provider::Anthropic.structured_output_system(instructions, model, TOOL_NAME),
      messages: [ { role: "user", content: user_content } ],
      tools: [ output_tool ],
      tool_choice: Provider::Anthropic.structured_output_tool_choice(model, TOOL_NAME)
    )

    result = build_result(extract_tool_input(response))
    record_usage(model, response.usage, operation: OPERATION, metadata: { files: files.size, bytes: total_bytes })

    span&.end(output: result.to_h, usage: usage_hash(response.usage))
    result
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    record_usage_error(model, operation: OPERATION, error: e, metadata: { files: files&.size })
    raise
  end

  private
    ReceiptExtraction = Provider::LlmConcept::ReceiptExtraction

    def total_bytes
      @total_bytes ||= Array(files).sum { |file| file[:data].bytesize }
    end

    # Long supermarket receipts with every line item and raw_text need room.
    def max_tokens
      8192
    end

    def user_content
      blocks = files.map do |file|
        type = file[:content_type] == "application/pdf" ? "document" : "image"
        { type:, source: { type: "base64", media_type: file[:content_type], data: Base64.strict_encode64(file[:data]) } }
      end

      blocks << {
        type: "text",
        text: "Read the attached receipt (#{files.size} #{"file".pluralize(files.size)} of one document) " \
              "and return it via the #{TOOL_NAME} tool. Assign each line item to one of these categories, " \
              "or null when none fits: #{category_names.join(", ").presence || "(no categories)"}."
      }
    end

    def output_tool
      money = { type: [ "string", "null" ], description: "Decimal with a dot, e.g. 12.99" }
      date = { type: [ "string", "null" ], pattern: "^\\d{4}-\\d{2}-\\d{2}$", description: "YYYY-MM-DD or null" }

      {
        name: TOOL_NAME,
        description: "Return the structured contents of the receipt, bill or invoice.",
        input_schema: {
          type: "object",
          properties: {
            document_kind: { type: "string", enum: DOCUMENT_KINDS },
            merchant: { type: [ "string", "null" ] },
            nip: { type: [ "string", "null" ], description: "Seller tax id (NIP), digits only" },
            date: date.merge(description: "Sale date (receipt) or issue date (invoice)"),
            due_date: date.merge(description: "Payment due date on invoices and bills"),
            total: money.merge(description: "Amount paid, e.g. the SUMA PLN line"),
            currency: { type: [ "string", "null" ], description: "ISO 4217 code" },
            payment_method: { type: "string", enum: PAYMENT_METHODS },
            vat_breakdown: {
              type: "array",
              items: {
                type: "object",
                properties: { letter: { type: [ "string", "null" ] }, rate: money, net: money, vat: money, gross: money },
                required: %w[letter rate net vat gross],
                additionalProperties: false
              }
            },
            line_items: {
              type: "array",
              items: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  quantity: money,
                  amount: money.merge(description: "Line total before line discount"),
                  discount: money.merge(description: "Positive discount on this line (RABAT), 0 when none"),
                  category_name: { type: [ "string", "null" ], enum: category_names + [ nil ] }
                },
                required: %w[name quantity amount discount category_name],
                additionalProperties: false
              }
            },
            confidence: {
              type: "object",
              description: "0..1 confidence per field you read, e.g. {\"total\": 0.9}",
              additionalProperties: { type: "number" }
            },
            raw_text: { type: [ "string", "null" ], description: "The receipt text as read" }
          },
          required: %w[document_kind merchant nip date due_date total currency payment_method vat_breakdown line_items confidence raw_text],
          additionalProperties: false
        }
      }
    end

    def instructions
      <<~INSTRUCTIONS
        You read photographed or scanned receipts, bills and invoices and return their contents
        via the #{TOOL_NAME} tool. Several images are pages or parts of the same document.

        Rules:
          - Report only what is printed. Return null for anything unreadable; never guess numbers.
          - total is the amount paid. On Polish fiscal receipts it is the "SUMA PLN" / "SUMA" line.
            Never use "RESZTA" (change), "GOTÓWKA" (cash tendered) or "KARTA" lines as the total.
          - vat_breakdown comes from the "PTU A 23%" style lines; read each letter's rate from the
            receipt rather than assuming one.
          - A refund or return ("ZWROT", "Paragon zwrotu", "Faktura korygująca" lowering the amount)
            is money coming back: give it a negative total, and negative line item amounts.
          - A printout marked "NIEFISKALNY" is not a fiscal receipt: document_kind "other".
          - Invoices ("Faktura", "Rachunek") and utility bills are document_kind "invoice";
            give the issue date as date and the payment deadline ("termin płatności") as due_date.
          - payment_method: "card" for card/BLIK/phone payments, "cash" for cash, "mixed" when both.
          - Line item amount is the line total; a discount ("RABAT", "OBNIŻKA") under a line goes in
            that line's discount as a positive number.
          - category_name must be one of the given category names exactly, or null.
          - Dates as YYYY-MM-DD, amounts with a dot as decimal separator.
      INSTRUCTIONS
    end

    def extract_tool_input(response)
      tool_use = Array(response.content).find { |block| structured_block_type(block) == :tool_use }
      raise Provider::Anthropic::Error, "Model did not invoke #{TOOL_NAME} (stop_reason: #{response.stop_reason})" unless tool_use

      input = structured_block_input(tool_use)
      input = JSON.parse(input) if input.is_a?(String)
      input.deep_stringify_keys
    end

    def build_result(parsed)
      ReceiptExtraction.new(
        document_kind: parsed["document_kind"].to_s.in?(DOCUMENT_KINDS) ? parsed["document_kind"].to_s : "other",
        merchant: parsed["merchant"].presence,
        nip: parsed["nip"].to_s.gsub(/\D/, "").presence,
        date: parse_date(parsed["date"]),
        due_date: parse_date(parsed["due_date"]),
        total: parse_decimal(parsed["total"]),
        currency: parsed["currency"].to_s.upcase.presence,
        payment_method: parsed["payment_method"].to_s.in?(PAYMENT_METHODS) ? parsed["payment_method"].to_s : "unknown",
        vat_breakdown: Array(parsed["vat_breakdown"]).map { |row| row.to_h.stringify_keys },
        line_items: Array(parsed["line_items"]).map { |row| row.to_h.stringify_keys },
        confidence: parsed["confidence"].is_a?(Hash) ? parsed["confidence"] : {},
        raw_text: parsed["raw_text"].presence
      )
    end

    def parse_date(value)
      Date.strptime(value.to_s, "%Y-%m-%d")
    rescue Date::Error
      nil
    end

    def parse_decimal(value)
      return nil unless value.to_s.match?(/\A-?\d+(\.\d+)?\z/)

      BigDecimal(value.to_s)
    end
end
