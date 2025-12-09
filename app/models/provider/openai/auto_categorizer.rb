class Provider::Openai::AutoCategorizer
  include Provider::Openai::Concerns::UsageRecorder

  # JSON response format modes for custom providers
  # - "strict": Use strict JSON schema (requires full OpenAI API compatibility)
  # - "json_object": Use json_object response format (broader compatibility)
  # - "none": No response format constraint (maximum compatibility with local LLMs)
  JSON_MODE_STRICT = "strict"
  JSON_MODE_OBJECT = "json_object"
  JSON_MODE_NONE = "none"
  JSON_MODE_AUTO = "auto"

  # Threshold for auto mode: if more than this percentage returns null, retry with none mode
  # This is a heuristic to detect when strict JSON mode is breaking the model's ability to reason
  AUTO_MODE_NULL_THRESHOLD = 0.5

  attr_reader :client, :model, :transactions, :user_categories, :custom_provider, :langfuse_trace, :family, :json_mode

  def initialize(client, model: "", transactions: [], user_categories: [], custom_provider: false, langfuse_trace: nil, family: nil, json_mode: nil)
    @client = client
    @model = model
    @transactions = transactions
    @user_categories = user_categories
    @custom_provider = custom_provider
    @langfuse_trace = langfuse_trace
    @family = family
    @json_mode = json_mode || default_json_mode
  end

  VALID_JSON_MODES = [ JSON_MODE_STRICT, JSON_MODE_OBJECT, JSON_MODE_NONE, JSON_MODE_AUTO ].freeze

  # Determine default JSON mode based on configuration hierarchy:
  # 1. Environment variable (LLM_JSON_MODE) - highest priority, for testing/override
  # 2. Setting.openai_json_mode - user-configured in app settings
  # 3. Default: auto mode (recommended for all providers)
  #
  # Mode descriptions:
  # - "auto": Tries strict first, falls back to none if >50% fail (recommended default)
  # - "strict": Best for thinking models (qwen-thinking, deepseek-reasoner) - skips verbose <think> tags
  # - "none": Best for non-thinking models (gpt-oss, llama, mistral) - allows reasoning in output
  # - "json_object": Middle ground, broader compatibility than strict
  def default_json_mode
    # 1. Check environment variable first (allows runtime override for testing)
    env_mode = ENV["LLM_JSON_MODE"]
    return env_mode if env_mode.present? && VALID_JSON_MODES.include?(env_mode)

    # 2. Check app settings (user-configured)
    setting_mode = Setting.openai_json_mode
    return setting_mode if setting_mode.present? && VALID_JSON_MODES.include?(setting_mode)

    # 3. Default: auto mode for all providers (tries strict first, falls back to none if needed)
    JSON_MODE_AUTO
  end

  def auto_categorize
    if custom_provider
      auto_categorize_openai_generic
    else
      auto_categorize_openai_native
    end
  end

  def instructions
    if custom_provider
      simple_instructions
    else
      detailed_instructions
    end
  end

  # Simplified instructions for smaller/local LLMs
  def simple_instructions
    <<~INSTRUCTIONS.strip_heredoc
      Categorize transactions into the given categories. Return JSON only. Do not explain your reasoning.

      CRITICAL RULES:
      1. Match transaction_id exactly from input
      2. Use EXACT category_name from the provided list, or "null" if unsure
      3. Match expense transactions to expense categories only
      4. Match income transactions to income categories only
      5. Return "null" if the description is generic/ambiguous (e.g., "POS DEBIT", "ACH WITHDRAWAL", "CHECK #1234")
      6. Prefer MORE SPECIFIC subcategories over general parent categories when available

      CATEGORY HIERARCHY NOTES:
      - Use "Restaurants" for sit-down restaurants, "Fast Food" for quick service chains
      - Use "Coffee Shops" for coffee places, "Food & Drink" only when type is unclear
      - Use "Shopping" for general retail, big-box stores, and online marketplaces
      - Use "Groceries" for dedicated grocery stores ONLY
      - For income: use "Salary" for payroll/employer deposits, "Income" for generic income sources

      Output JSON format only (no markdown, no explanation):
      {"categorizations": [{"transaction_id": "...", "category_name": "..."}]}
    INSTRUCTIONS
  end

  # Detailed instructions for larger models like GPT-4
  def detailed_instructions
    <<~INSTRUCTIONS.strip_heredoc
      You are an assistant to a consumer personal finance app.  You will be provided a list
      of the user's transactions and a list of the user's categories.  Your job is to auto-categorize
      each transaction.

      Closely follow ALL the rules below while auto-categorizing:

      - Return 1 result per transaction
      - Correlate each transaction by ID (transaction_id)
      - Attempt to match the most specific category possible (i.e. subcategory over parent category)
      - Category and transaction classifications should match (i.e. if transaction is an "expense", the category must have classification of "expense")
      - If you don't know the category, return "null"
        - You should always favor "null" over false positives
        - Be slightly pessimistic.  Only match a category if you're 60%+ confident it is the correct one.
      - Each transaction has varying metadata that can be used to determine the category
        - Note: "hint" comes from 3rd party aggregators and typically represents a category name that
          may or may not match any of the user-supplied categories
    INSTRUCTIONS
  end

  private

    def auto_categorize_openai_native
      span = langfuse_trace&.span(name: "auto_categorize_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        user_categories: user_categories
      })

      response = client.responses.create(parameters: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        input: [ { role: "developer", content: developer_message } ],
        text: {
          format: {
            type: "json_schema",
            name: "auto_categorize_personal_finance_transactions",
            strict: true,
            schema: json_schema
          }
        },
        instructions: instructions
      })
      Rails.logger.info("Tokens used to auto-categorize transactions: #{response.dig("usage", "total_tokens")}")

      categorizations = extract_categorizations_native(response)
      result = build_response(categorizations)

      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "auto_categorize",
        metadata: {
          transaction_count: transactions.size,
          category_count: user_categories.size
        }
      )

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    def auto_categorize_openai_generic
      if json_mode == JSON_MODE_AUTO
        auto_categorize_with_auto_mode
      else
        auto_categorize_with_mode(json_mode)
      end
    rescue Faraday::BadRequestError => e
      # If strict mode fails (HTTP 400), fall back to none mode
      # This handles providers that don't support json_schema response format
      if json_mode == JSON_MODE_STRICT || json_mode == JSON_MODE_AUTO
        Rails.logger.warn("Strict JSON mode failed, falling back to none mode: #{e.message}")
        auto_categorize_with_mode(JSON_MODE_NONE)
      else
        raise
      end
    end

    # Auto mode: try strict first, fall back to none if too many nulls or missing results
    #
    # This uses pure heuristics to detect when strict JSON mode is breaking the model's
    # ability to reason. Models that can't reason well in strict mode often:
    # 1. Return null for everything, OR
    # 2. Simply omit transactions they can't categorize (returning fewer results than input)
    #
    # The heuristic is simple: if >50% of results are null or missing, the model likely
    # needs the freedom to reason in its output (which strict mode prevents).
    def auto_categorize_with_auto_mode
      result = auto_categorize_with_mode(JSON_MODE_STRICT)

      null_count = result.count { |r| r.category_name.nil? || r.category_name == "null" }
      missing_count = transactions.size - result.size
      failed_count = null_count + missing_count
      failed_ratio = transactions.size > 0 ? failed_count.to_f / transactions.size : 0.0

      if failed_ratio > AUTO_MODE_NULL_THRESHOLD
        Rails.logger.info("Auto mode: #{(failed_ratio * 100).round}% failed (#{null_count} nulls, #{missing_count} missing) in strict mode, retrying with none mode")
        auto_categorize_with_mode(JSON_MODE_NONE)
      else
        result
      end
    end

    def auto_categorize_with_mode(mode)
      span = langfuse_trace&.span(name: "auto_categorize_api_call", input: {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        transactions: transactions,
        user_categories: user_categories,
        json_mode: mode
      })

      # Build parameters with configurable JSON response format
      params = {
        model: model.presence || Provider::Openai::DEFAULT_MODEL,
        messages: [
          { role: "system", content: instructions },
          { role: "user", content: developer_message_for_generic }
        ]
      }

      # Add response format based on json_mode setting
      case mode
      when JSON_MODE_STRICT
        params[:response_format] = {
          type: "json_schema",
          json_schema: {
            name: "auto_categorize_personal_finance_transactions",
            strict: true,
            schema: json_schema
          }
        }
      when JSON_MODE_OBJECT
        params[:response_format] = { type: "json_object" }
        # JSON_MODE_NONE: no response_format constraint
      end

      response = client.chat(parameters: params)

      Rails.logger.info("Tokens used to auto-categorize transactions: #{response.dig("usage", "total_tokens")} (json_mode: #{mode})")

      categorizations = extract_categorizations_generic(response)
      result = build_response(categorizations)

      record_usage(
        model.presence || Provider::Openai::DEFAULT_MODEL,
        response.dig("usage"),
        operation: "auto_categorize",
        metadata: {
          transaction_count: transactions.size,
          category_count: user_categories.size,
          json_mode: mode
        }
      )

      span&.end(output: result.map(&:to_h), usage: response.dig("usage"))
      result
    rescue => e
      span&.end(output: { error: e.message }, level: "ERROR")
      raise
    end

    AutoCategorization = Provider::LlmConcept::AutoCategorization

    def build_response(categorizations)
      categorizations.map do |categorization|
        AutoCategorization.new(
          transaction_id: categorization.dig("transaction_id"),
          category_name: normalize_category_name(categorization.dig("category_name")),
        )
      end
    end

    def normalize_category_name(category_name)
      # Convert to string to handle non-string LLM outputs (numbers, booleans, etc.)
      normalized = category_name.to_s.strip
      return nil if normalized.empty? || normalized == "null" || normalized.downcase == "null"

      # Try exact match first
      exact_match = user_categories.find { |c| c[:name] == normalized }
      return exact_match[:name] if exact_match

      # Try case-insensitive match
      case_insensitive_match = user_categories.find { |c| c[:name].to_s.downcase == normalized.downcase }
      return case_insensitive_match[:name] if case_insensitive_match

      # Try partial/fuzzy match (for common variations)
      fuzzy_match = find_fuzzy_category_match(normalized)
      return fuzzy_match if fuzzy_match

      # Return normalized string if no match found (will be treated as uncategorized)
      normalized
    end

    # Find a fuzzy match for category names with common variations
    def find_fuzzy_category_match(category_name)
      # Ensure string input for string operations
      input_str = category_name.to_s
      normalized_input = input_str.downcase.gsub(/[^a-z0-9]/, "")

      user_categories.each do |cat|
        cat_name_str = cat[:name].to_s
        normalized_cat = cat_name_str.downcase.gsub(/[^a-z0-9]/, "")

        # Check if one contains the other
        return cat[:name] if normalized_input.include?(normalized_cat) || normalized_cat.include?(normalized_input)

        # Check common abbreviations/variations
        return cat[:name] if fuzzy_name_match?(input_str, cat_name_str)
      end

      nil
    end

    # Handle common naming variations
    def fuzzy_name_match?(input, category)
      variations = {
        "gas" => [ "gas & fuel", "gas and fuel", "fuel", "gasoline" ],
        "restaurants" => [ "restaurant", "dining", "food" ],
        "groceries" => [ "grocery", "supermarket", "food store" ],
        "streaming" => [ "streaming services", "streaming service" ],
        "rideshare" => [ "ride share", "ride-share", "uber", "lyft" ],
        "coffee" => [ "coffee shops", "coffee shop", "cafe" ],
        "fast food" => [ "fastfood", "quick service" ],
        "gym" => [ "gym & fitness", "fitness", "gym and fitness" ],
        "flights" => [ "flight", "airline", "airlines", "airfare" ],
        "hotels" => [ "hotel", "lodging", "accommodation" ]
      }

      # Ensure string inputs for string operations
      input_lower = input.to_s.downcase
      category_lower = category.to_s.downcase

      variations.each do |_key, synonyms|
        if synonyms.include?(input_lower) && synonyms.include?(category_lower)
          return true
        end
      end

      false
    end

    def extract_categorizations_native(response)
      # Find the message output (not reasoning output)
      message_output = response["output"]&.find { |o| o["type"] == "message" }
      raw = message_output&.dig("content", 0, "text")

      raise Provider::Openai::Error, "No message content found in response" if raw.nil?

      JSON.parse(raw).dig("categorizations")
    rescue JSON::ParserError => e
      raise Provider::Openai::Error, "Invalid JSON in native categorization: #{e.message}"
    end

    def extract_categorizations_generic(response)
      raw = response.dig("choices", 0, "message", "content")
      parsed = parse_json_flexibly(raw)

      # Handle different response formats from various LLMs
      categorizations = parsed.dig("categorizations") ||
                        parsed.dig("results") ||
                        (parsed.is_a?(Array) ? parsed : nil)

      raise Provider::Openai::Error, "Could not find categorizations in response" if categorizations.nil?

      # Normalize field names (some LLMs use different naming)
      categorizations.map do |cat|
        {
          "transaction_id" => cat["transaction_id"] || cat["id"] || cat["txn_id"],
          "category_name" => cat["category_name"] || cat["category"] || cat["name"]
        }
      end
    end

    # Flexible JSON parsing that handles common LLM output issues
    def parse_json_flexibly(raw)
      return {} if raw.blank?

      # Strip thinking model tags if present (e.g., <think>...</think>)
      # The actual JSON output comes after the thinking block
      cleaned = strip_thinking_tags(raw)

      # Try direct parse first
      JSON.parse(cleaned)
    rescue JSON::ParserError
      # Try multiple extraction strategies in order of preference

      # Strategy 1: Closed markdown code blocks (```json...```)
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        matches = cleaned.scan(/```(?:json)?\s*(\{[\s\S]*?\})\s*```/m).flatten
        matches.reverse_each do |match|
          begin
            return JSON.parse(match)
          rescue JSON::ParserError
            next
          end
        end
      end

      # Strategy 2: Unclosed markdown code blocks (thinking models often forget to close)
      # Pattern: ```json followed by JSON that goes to end of string
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*\})\s*$/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Continue to next strategy
        end
      end

      # Strategy 3: Find JSON object with "categorizations" key
      if cleaned =~ /(\{"categorizations"\s*:\s*\[[\s\S]*\]\s*\})/m
        matches = cleaned.scan(/(\{"categorizations"\s*:\s*\[[\s\S]*?\]\s*\})/m).flatten
        matches.reverse_each do |match|
          begin
            return JSON.parse(match)
          rescue JSON::ParserError
            next
          end
        end
        # Try greedy match if non-greedy failed
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Continue to next strategy
        end
      end

      # Strategy 4: Find any JSON object (last resort)
      if cleaned =~ /(\{[\s\S]*\})/m
        begin
          return JSON.parse($1)
        rescue JSON::ParserError
          # Fall through to error
        end
      end

      raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
    end

    # Strip thinking model tags (<think>...</think>) from response
    # Some models like Qwen-thinking output reasoning in these tags before the actual response
    def strip_thinking_tags(raw)
      # Remove <think>...</think> blocks but keep content after them
      # If no closing tag, the model may have been cut off - try to extract JSON from inside
      if raw.include?("<think>")
        # Check if there's content after the thinking block
        if raw =~ /<\/think>\s*([\s\S]*)/m
          after_thinking = $1.strip
          return after_thinking if after_thinking.present?
        end
        # If no content after </think> or no closing tag, look inside the thinking block
        # The JSON might be the last thing in the thinking block
        if raw =~ /<think>([\s\S]*)/m
          return $1
        end
      end
      raw
    end

    def json_schema
      {
        type: "object",
        properties: {
          categorizations: {
            type: "array",
            description: "An array of auto-categorizations for each transaction",
            items: {
              type: "object",
              properties: {
                transaction_id: {
                  type: "string",
                  description: "The internal ID of the original transaction",
                  enum: transactions.map { |t| t[:id] }
                },
                category_name: {
                  type: "string",
                  description: "The matched category name of the transaction, or null if no match",
                  enum: [ *user_categories.map { |c| c[:name] }, "null" ]
                }
              },
              required: [ "transaction_id", "category_name" ],
              additionalProperties: false
            }
          }
        },
        required: [ "categorizations" ],
        additionalProperties: false
      }
    end

    def developer_message
      <<~MESSAGE.strip_heredoc
        Here are the user's available categories in JSON format:

        ```json
        #{user_categories.to_json}
        ```

        Use the available categories to auto-categorize the following transactions:

        ```json
        #{transactions.to_json}
        ```
      MESSAGE
    end

    # Concise developer message optimized for smaller/local LLMs
    # Uses pattern-based guidance instead of exhaustive examples
    def developer_message_for_generic
      <<~MESSAGE.strip_heredoc
        AVAILABLE CATEGORIES: #{user_categories.map { |c| c[:name] }.join(", ")}

        TRANSACTIONS TO CATEGORIZE:
        #{format_transactions_simply}

        CATEGORIZATION GUIDELINES:
        - Prefer specific subcategories over general parent categories when confident
        - Food delivery services should be categorized based on the underlying merchant type
        - Square payments (SQ *) should be inferred from the merchant name after the prefix
        - Warehouse/club stores should be categorized based on their primary purpose
        - Return "null" for generic transactions (e.g., POS terminals, wire transfers, checks, ATM withdrawals)

        IMPORTANT:
        - Use EXACT category names from the list above
        - Return "null" (as a string) if you cannot confidently match a category
        - Match expense transactions only to expense categories
        - Match income transactions only to income categories
        - Do NOT include any explanation or reasoning - only output JSON

        Respond with ONLY this JSON (no markdown code blocks, no other text):
        {"categorizations": [{"transaction_id": "...", "category_name": "..."}]}
      MESSAGE
    end

    # Format transactions in a simpler, more readable way for smaller LLMs
    def format_transactions_simply
      transactions.map do |t|
        "- ID: #{t[:id]}, Amount: #{t[:amount]}, Type: #{t[:classification]}, Description: \"#{t[:description]}\""
      end.join("\n")
    end
end
