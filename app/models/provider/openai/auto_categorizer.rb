class Provider::Openai::AutoCategorizer
  include Provider::Openai::Concerns::UsageRecorder

  # JSON response format modes for custom providers
  # - "strict": Use strict JSON schema (requires full OpenAI API compatibility)
  # - "json_object": Use json_object response format (broader compatibility)
  # - "none": No response format constraint (maximum compatibility with local LLMs)
  JSON_MODE_STRICT = "strict"
  JSON_MODE_OBJECT = "json_object"
  JSON_MODE_NONE = "none"

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

  # Determine default JSON mode based on environment and provider type
  def default_json_mode
    # Check environment variable first (allows global override)
    env_mode = ENV["LLM_JSON_MODE"]
    return env_mode if env_mode.present? && [ JSON_MODE_STRICT, JSON_MODE_OBJECT, JSON_MODE_NONE ].include?(env_mode)

    # Use strict mode by default - it's faster, uses fewer tokens, and produces cleaner output
    # Strict mode with enum constraints forces the model to output valid JSON without thinking tags
    # Falls back to none mode if strict mode fails (see auto_categorize_openai_generic)
    JSON_MODE_STRICT
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
      auto_categorize_with_mode(json_mode)
    rescue Faraday::BadRequestError => e
      # If strict mode fails (HTTP 400), fall back to none mode
      # This handles providers that don't support json_schema response format
      if json_mode == JSON_MODE_STRICT
        Rails.logger.warn("Strict JSON mode failed, falling back to none mode: #{e.message}")
        auto_categorize_with_mode(JSON_MODE_NONE)
      else
        raise
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
      return nil if category_name.nil? || category_name == "null" || category_name.downcase == "null"

      # Try exact match first
      exact_match = user_categories.find { |c| c[:name] == category_name }
      return exact_match[:name] if exact_match

      # Try case-insensitive match
      case_insensitive_match = user_categories.find { |c| c[:name].downcase == category_name.downcase }
      return case_insensitive_match[:name] if case_insensitive_match

      # Try partial/fuzzy match (for common variations)
      fuzzy_match = find_fuzzy_category_match(category_name)
      return fuzzy_match if fuzzy_match

      # Return original if no match found (will be treated as uncategorized)
      category_name
    end

    # Find a fuzzy match for category names with common variations
    def find_fuzzy_category_match(category_name)
      normalized_input = category_name.downcase.gsub(/[^a-z0-9]/, "")

      user_categories.each do |cat|
        normalized_cat = cat[:name].downcase.gsub(/[^a-z0-9]/, "")

        # Check if one contains the other
        return cat[:name] if normalized_input.include?(normalized_cat) || normalized_cat.include?(normalized_input)

        # Check common abbreviations/variations
        return cat[:name] if fuzzy_name_match?(category_name, cat[:name])
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

      input_lower = input.downcase
      category_lower = category.downcase

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
      # Try to extract JSON from markdown code blocks (greedy to get last/complete one)
      # Use reverse to find the last JSON block (thinking models often have incomplete JSON earlier)
      if cleaned =~ /```(?:json)?\s*(\{[\s\S]*?\})\s*```/m
        # Find all matches and use the last complete one
        matches = cleaned.scan(/```(?:json)?\s*(\{[\s\S]*?\})\s*```/m).flatten
        last_valid_json = nil
        matches.reverse_each do |match|
          begin
            last_valid_json = JSON.parse(match)
            break
          rescue JSON::ParserError
            next
          end
        end
        return last_valid_json if last_valid_json

        # Fall back to first match
        JSON.parse($1)
      # Try to find a JSON object anywhere in the response (use last complete one)
      elsif cleaned =~ /(\{[\s\S]*\})/m
        # Find all potential JSON objects
        potential_jsons = cleaned.scan(/(\{"categorizations"[\s\S]*?\}\s*\][\s\S]*?\})/m).flatten
        if potential_jsons.any?
          potential_jsons.reverse_each do |match|
            begin
              return JSON.parse(match)
            rescue JSON::ParserError
              next
            end
          end
        end
        # Fall back to greedy match
        JSON.parse($1)
      else
        raise Provider::Openai::Error, "Could not parse JSON from response: #{raw.truncate(200)}"
      end
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

    # Enhanced developer message with few-shot examples for smaller/local LLMs
    def developer_message_for_generic
      category_names = user_categories.map { |c| c[:name] }.join(", ")

      <<~MESSAGE.strip_heredoc
        AVAILABLE CATEGORIES: #{category_names}

        TRANSACTIONS TO CATEGORIZE:
        #{format_transactions_simply}

        EXAMPLES of correct categorization:
        FAST FOOD chains (use "Fast Food"):
        - "MCDONALD'S #12345" → "Fast Food"
        - "CHIPOTLE ONLINE" → "Fast Food"
        - "TACO BELL #789" → "Fast Food"
        - "DOORDASH*CHIPOTLE" → "Restaurants" (delivery services use "Restaurants")

        COFFEE (use "Coffee Shops"):
        - "STARBUCKS STORE" → "Coffee Shops"
        - "DUNKIN #12345" → "Coffee Shops"
        - "PEETS COFFEE" → "Coffee Shops"
        - "SQ *DOWNTOWN CAFE" → "Coffee Shops" (SQ = Square, CAFE = coffee shop)

        SIT-DOWN restaurants (use "Restaurants"):
        - "OLIVE GARDEN #456" → "Restaurants"
        - "CHEESECAKE FACTORY" → "Restaurants"
        - "GRUBHUB*THAI KITCHEN" → "Restaurants"
        - "UBEREATS *UBER EATS" → "Restaurants"
        - "PANERA BREAD #567" → "Restaurants"

        GAS STATIONS (use "Gas & Fuel"):
        - "SHELL OIL 12345" → "Gas & Fuel"
        - "CHEVRON STATION" → "Gas & Fuel"

        GROCERIES (dedicated grocery stores and convenience stores):
        - "WHOLE FOODS MKT" → "Groceries"
        - "TRADER JOE'S" → "Groceries"
        - "INSTACART*SAFEWAY" → "Groceries"
        - "7-ELEVEN #34567" → "Groceries"

        SHOPPING (retail stores, big-box, online marketplaces):
        - "TARGET #1234" → "Shopping"
        - "WALMART SUPERCENTER" → "Shopping"
        - "AMAZON.COM*..." → "Shopping"
        - "COSTCO.COM" → "Shopping"
        - "COSTCO WHSE #1234" → "Groceries" (in-store warehouse = groceries)

        STREAMING (use "Streaming Services"):
        - "NETFLIX.COM" → "Streaming Services"
        - "SPOTIFY USA" → "Streaming Services"
        - "HBO MAX" → "Streaming Services"

        SUBSCRIPTIONS (non-streaming services):
        - "APPLE.COM/BILL" → "Subscriptions"
        - "GOOGLE *STORAGE" → "Subscriptions"
        - "AMAZON PRIME*..." → "Subscriptions"

        INCOME (use classification "income"):
        - "DIRECT DEPOSIT PAYROLL" → "Salary"
        - "ACME CORP PAYROLL" → "Salary"
        - "EMPLOYER DIRECT DEP" → "Salary"
        - "VENMO CASHOUT" → "Income" (generic income, not salary)
        - "ZELLE FROM JOHN S" → "Income" (person-to-person transfer)
        - "CASH APP*CASH OUT" → "Income"

        RETURN "null" for these (too generic/ambiguous):
        - "ACH WITHDRAWAL" → "null"
        - "POS DEBIT 12345" → "null"
        - "DEBIT CARD PURCHASE" → "null"
        - "CHECK #1234" → "null"
        - "WIRE TRANSFER OUT" → "null"
        - "ATM WITHDRAWAL" → "null"
        - "PAYPAL *JOHNSMITH" → "null" (unknown purpose)
        - "PENDING AUTHORIZATION" → "null"
        - "VOID TRANSACTION" → "null"
        - "SERVICE CHARGE" → "null"

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
