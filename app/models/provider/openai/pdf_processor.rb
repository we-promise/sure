class Provider::Openai::PdfProcessor
  include Provider::Openai::Concerns::UsageRecorder

  attr_reader :client, :model, :pdf_content, :custom_provider, :langfuse_trace, :family, :max_response_tokens

  def initialize(client, model: "", pdf_content: nil, custom_provider: false, langfuse_trace: nil, family: nil, max_response_tokens:)
    @client = client
    @model = model
    @pdf_content = pdf_content
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
    @max_response_tokens = max_response_tokens
  end

  def process
    span = langfuse_trace&.span(name: "process_pdf_api_call", input: {
      model: model.presence || Provider::Openai::DEFAULT_MODEL,
      pdf_size: pdf_content&.bytesize
    })

    # Try text extraction first (works with all models)
    # Fall back to vision API with images if text extraction fails (for scanned PDFs)
    response = begin
      process_with_text_extraction
    rescue Provider::Openai::Error => e
      Rails.logger.warn("Text extraction failed: #{e.message}, trying vision API with images")
      process_with_vision
    end

    span&.end(output: response.to_h)
    response
  rescue => e
    span&.end(output: { error: e.message }, level: "ERROR")
    raise
  end

  def instructions
    <<~INSTRUCTIONS.strip
      You are a financial document analysis assistant. Your job is to analyze uploaded PDF documents
      and provide a structured summary of what the document contains.

      For each document, you must determine:

      1. **Document Type**: Classify the document as one of the following:
         - `bank_statement`: A bank account statement showing transactions, balances, and account activity. This includes mobile money statements (like M-PESA, Venmo, PayPal, Cash App), digital wallet statements, and any statement showing a list of financial transactions with dates and amounts.
         - `credit_card_statement`: A credit card statement showing charges, payments, and balances
         - `investment_statement`: An investment/brokerage statement showing holdings, trades, or portfolio performance
         - `financial_document`: General financial documents like tax forms, receipts, invoices, or financial reports
         - `contract`: Legal agreements, loan documents, terms of service, or policy documents
         - `other`: Any document that doesn't fit the above categories

      2. **Summary**: Provide a concise summary of the document that includes:
         - The issuing institution or company name (if identifiable)
         - The date range or statement period (if applicable)
         - Key financial figures (account balances, total transactions, etc.)
         - The account holder's name (if visible, use "Account Holder" if redacted)
         - Any notable items or important information

      3. **Extracted Data**: If the document is a statement with transactions, extract key metadata:
         - Number of transactions (if countable)
         - Statement period (start and end dates)
         - Opening and closing balances (if visible)
         - Currency used

      4. **Reconciliation Check** (ONLY for bank_statement or credit_card_statement):
         - First, use available tools to get accounts and their transactions for the relevant time period
         - Match the statement to the correct account by comparing institution name, account holder, or account number
         - Compare the statement closing balance with the account balance as of statement_period_end (NOT current balance)
         - Count transactions in the statement and compare with synced transaction count for that period
         - Match individual transactions (by date within ±1 day, amount within ±$0.10, similar description)
         - Report which transactions are new (in statement but not synced) and which are missing (synced but not in statement)

      IMPORTANT GUIDELINES:
      - Be factual and precise - only report what you can clearly see in the document
      - If information is unclear or redacted, note it as "not clearly visible" or "redacted"
      - Do NOT make assumptions about data you cannot see
      - For statements with many transactions, provide a count rather than listing each one
      - Focus on providing actionable information that helps the user understand what they uploaded
      - If the document is unreadable or the PDF is corrupted, indicate this clearly

      Respond with ONLY valid JSON in this exact format (no markdown code blocks, no other text):
      {
        "document_type": "bank_statement|credit_card_statement|investment_statement|financial_document|contract|other",
        "summary": "A clear, concise summary of the document contents...",
        "extracted_data": {
          "institution_name": "Name of bank/company or null",
          "statement_period_start": "YYYY-MM-DD or null",
          "statement_period_end": "YYYY-MM-DD or null",
          "transaction_count": number or null,
          "opening_balance": number or null,
          "closing_balance": number or null,
          "currency": "USD/EUR/etc or null",
          "account_holder": "Name or null"
        },
        "reconciliation": {
          "performed": true|false,
          "account_id": "account_id or null",
          "balance_match": true|false|null,
          "statement_closing_balance": number|null,
          "synced_closing_balance": number|null,
          "statement_transaction_count": number|null,
          "synced_transaction_count": number|null,
          "matched_count": number|null,
          "new_count": number|null,
          "missing_count": number|null,
          "new_transactions": [{"date":"YYYY-MM-DD","amount":0.00,"description":"..."}],
          "missing_transactions": [{"date":"YYYY-MM-DD","amount":0.00,"description":"..."}]
        }
      }
    INSTRUCTIONS
  end

  private

    PdfProcessingResult = Provider::LlmConcept::PdfProcessingResult

    def process_with_text_extraction
      effective_model = model.presence || Provider::Openai::DEFAULT_MODEL

      # Extract text from PDF using pdf-reader gem
      pdf_text = extract_text_from_pdf
      raise Provider::Openai::Error, "Could not extract text from PDF" if pdf_text.blank?

      # Truncate if too long (max ~100k chars to stay within token limits)
      pdf_text = pdf_text.truncate(100_000) if pdf_text.length > 100_000

      params = {
        model: effective_model,
        messages: [
          { role: "system", content: instructions },
          {
            role: "user",
            content: "Please analyze the following document text and provide a structured summary:\n\n#{pdf_text}"
          }
        ],
        response_format: { type: "json_object" }
      }

      response, total_usage = run_reconciliation_tool_loop(params)

      Rails.logger.info("Tokens used to process PDF: #{total_usage["total_tokens"]}")

      record_usage(
        effective_model,
        total_usage,
        operation: "process_pdf",
        metadata: { pdf_size: pdf_content&.bytesize }
      )

      parse_response_generic(response)
    end

    def extract_text_from_pdf
      return nil if pdf_content.blank?

      reader = PDF::Reader.new(StringIO.new(pdf_content))
      text_parts = []

      reader.pages.each_with_index do |page, index|
        text_parts << "--- Page #{index + 1} ---"
        text_parts << page.text
      end

      text_parts.join("\n\n")
    rescue => e
      Rails.logger.error("Failed to extract text from PDF: #{e.message}")
      nil
    end

    def process_with_vision
      effective_model = model.presence || Provider::Openai::DEFAULT_MODEL

      # Convert PDF to images using pdftoppm
      images_base64 = convert_pdf_to_images
      raise Provider::Openai::Error, "Could not convert PDF to images" if images_base64.blank?

      # Build message content with images (max 5 pages to avoid token limits)
      content = []
      images_base64.first(5).each do |img_base64|
        content << {
          type: "image_url",
          image_url: {
            url: "data:image/png;base64,#{img_base64}",
            detail: "low"
          }
        }
      end
      content << {
        type: "text",
        text: "Please analyze this PDF document (#{images_base64.size} pages total, showing first #{[ images_base64.size, 5 ].min}) and respond with valid JSON only."
      }

      # Note: response_format is not compatible with vision, so we ask for JSON in the prompt
      params = {
        model: effective_model,
        messages: [
          { role: "system", content: instructions + "\n\nIMPORTANT: Respond with valid JSON only, no markdown or other formatting." },
          { role: "user", content: content }
        ],
        max_tokens: max_response_tokens
      }

      response, total_usage = run_reconciliation_tool_loop(params)

      Rails.logger.info("Tokens used to process PDF via vision: #{total_usage["total_tokens"]}")

      record_usage(
        effective_model,
        total_usage,
        operation: "process_pdf_vision",
        metadata: { pdf_size: pdf_content&.bytesize, pages: images_base64.size }
      )

      parse_response_generic(response)
    end

    def convert_pdf_to_images
      return [] if pdf_content.blank?

      Dir.mktmpdir do |tmpdir|
        pdf_path = File.join(tmpdir, "input.pdf")
        File.binwrite(pdf_path, pdf_content)

        # Convert PDF to PNG images using pdftoppm
        output_prefix = File.join(tmpdir, "page")
        system("pdftoppm", "-png", "-r", "150", pdf_path, output_prefix)

        # Read all generated images
        image_files = Dir.glob(File.join(tmpdir, "page-*.png")).sort
        image_files.map do |img_path|
          Base64.strict_encode64(File.binread(img_path))
        end
      end
    rescue => e
      Rails.logger.error("Failed to convert PDF to images: #{e.message}")
      []
    end

    def parse_response_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      parsed = parse_json_flexibly(raw)

      build_result(parsed)
    end

    def run_reconciliation_tool_loop(initial_params)
      tools = reconciliation_tools
      params = initial_params.deep_dup
      params[:tools] = tools if tools.present?

      response = nil
      total_usage = empty_usage_hash
      iteration = 0

      loop do
        response = client.chat(parameters: params)
        accumulate_usage!(total_usage, response["usage"])

        message = response.dig("choices", 0, "message") || {}
        tool_calls = message["tool_calls"] || []
        break if tool_calls.blank?

        iteration += 1
        if iteration > 8
          raise Provider::Openai::Error, "PDF reconciliation exceeded maximum tool-call iterations"
        end

        params[:messages] << {
          role: "assistant",
          content: message["content"] || "",
          tool_calls: tool_calls
        }

        tool_calls.each do |tool_call|
          tool_result = execute_reconciliation_tool_call(tool_call)

          params[:messages] << {
            role: "tool",
            tool_call_id: tool_call["id"],
            name: tool_call.dig("function", "name"),
            content: tool_result.to_json
          }
        end
      end

      [ response, total_usage ]
    end

    def reconciliation_tools
      return [] unless family.present?

      get_accounts_tool = Assistant::Function::GetAccounts.new(tool_user)
      get_transactions_tool = Assistant::Function::GetTransactions.new(tool_user)

      [
        {
          type: "function",
          function: {
            name: get_accounts_tool.name,
            description: get_accounts_tool.description,
            parameters: get_accounts_tool.params_schema
          }
        },
        {
          type: "function",
          function: {
            name: get_transactions_tool.name,
            description: get_transactions_tool.description,
            parameters: get_transactions_tool.params_schema
          }
        }
      ]
    end

    def execute_reconciliation_tool_call(tool_call)
      function_name = tool_call.dig("function", "name")
      args_raw = tool_call.dig("function", "arguments")
      args = args_raw.present? ? JSON.parse(args_raw) : {}

      case function_name
      when "get_accounts"
        Assistant::Function::GetAccounts.new(tool_user).call(args)
      when "get_transactions"
        normalized_args = normalize_get_transactions_args(args)
        result = Assistant::Function::GetTransactions.new(tool_user).call(normalized_args)
        augment_get_transactions_result_with_balance(result, normalized_args)
      else
        { error: "Unknown tool", function_name: function_name }
      end
    rescue JSON::ParserError => e
      { error: "Invalid tool arguments JSON", details: e.message }
    rescue => e
      { error: "Tool execution failed", function_name: function_name, details: e.message }
    end

    def tool_user
      @tool_user ||= family.users.find_by(role: "admin") || family.users.first
    end

    def normalize_get_transactions_args(args)
      normalized = args.deep_dup
      normalized["order"] ||= "desc"
      normalized["page"] ||= 1

      if normalized["account_id"].present? && normalized["accounts"].blank?
        account = family.accounts.find_by(id: normalized["account_id"])
        normalized["accounts"] = [ account.name ] if account.present?
      end

      normalized
    end

    def augment_get_transactions_result_with_balance(result, normalized_args)
      account_name = Array.wrap(normalized_args["accounts"]).first
      end_date = normalized_args["end_date"]
      return result unless account_name.present? && end_date.present?

      account = family.accounts.find_by(name: account_name)
      return result unless account

      parsed_end_date = Date.iso8601(end_date.to_s)
      balance_record = account.balances
        .where(currency: account.currency)
        .where("date <= ?", parsed_end_date)
        .order(date: :desc)
        .first

      result.merge(
        "balance_as_of_end_date" => balance_record&.end_balance&.to_f,
        "balance_record_date" => balance_record&.date&.iso8601
      )
    rescue ArgumentError
      result
    end

    def empty_usage_hash
      {
        "prompt_tokens" => 0,
        "completion_tokens" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "total_tokens" => 0
      }
    end

    def accumulate_usage!(total_usage, usage)
      return if usage.blank?

      total_usage["prompt_tokens"] += usage["prompt_tokens"].to_i
      total_usage["completion_tokens"] += usage["completion_tokens"].to_i
      total_usage["input_tokens"] += usage["input_tokens"].to_i
      total_usage["output_tokens"] += usage["output_tokens"].to_i
      total_usage["total_tokens"] += usage["total_tokens"].to_i
    end

    def build_result(parsed)
      PdfProcessingResult.new(
        summary: parsed["summary"],
        document_type: normalize_document_type(parsed["document_type"]),
        extracted_data: parsed["extracted_data"] || {},
        reconciliation: parsed["reconciliation"]
      )
    end

    def normalize_document_type(doc_type)
      return "other" if doc_type.blank?

      normalized = doc_type.to_s.strip.downcase.gsub(/\s+/, "_")
      Import::DOCUMENT_TYPES.include?(normalized) ? normalized : "other"
    end

    def parse_json_flexibly(raw)
      return {} if raw.blank?

      # Try direct parse first
      JSON.parse(raw)
    rescue JSON::ParserError
      # Try to extract JSON from markdown code blocks
      if raw =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Continue to next strategy
        end
      end

      # Try to find any JSON object
      if raw =~ /(\{[\s\S]*\})/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Fall through to error
        end
      end

      raise Provider::Openai::Error, "Could not parse JSON from PDF processing response: #{raw.truncate(200)}"
    end
end
