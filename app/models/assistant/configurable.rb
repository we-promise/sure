module Assistant::Configurable
  extend ActiveSupport::Concern

  class_methods do
    def config_for(chat)
      preferred_currency = Money::Currency.new(chat.user.family.currency)
      preferred_date_format = chat.user.family.date_format

      instructions_config = default_instructions(preferred_currency, preferred_date_format)

      {
        instructions: instructions_config[:content],
        instructions_prompt: instructions_config[:prompt],
        functions: default_functions
      }
    end

    private
      def default_functions
        [
          Assistant::Function::GetTransactions,
          Assistant::Function::GetAccounts,
          Assistant::Function::GetBalanceSheet,
          Assistant::Function::GetIncomeStatement
        ]
      end

      def default_instructions(preferred_currency, preferred_date_format)
        langfuse_instructions = langfuse_default_instructions(preferred_currency, preferred_date_format)

        if langfuse_instructions.present?
          {
            content: langfuse_instructions[:content],
            prompt: langfuse_instructions
          }
        else
          {
            content: fallback_default_instructions(preferred_currency, preferred_date_format),
            prompt: nil
          }
        end
      end

      def langfuse_default_instructions(preferred_currency, preferred_date_format)
        return unless langfuse_client

        prompt = langfuse_client.get_prompt("default_instructions")
        return if prompt.nil?

        # TODO: remove after we make the code resilient to chat vs. text types of prompts
        Rails.logger.warn("Langfuse prompt retrieved: #{prompt.name} #{prompt.version}")
        Rails.logger.warn("Langfuse prompt retrieved: #{prompt.prompt}")

        compiled_prompt = compile_langfuse_prompt(
          prompt.prompt.dig(0, "content"),
          preferred_currency: preferred_currency,
          preferred_date_format: preferred_date_format
        )

        content = extract_prompt_content(compiled_prompt)
        return if content.blank?

        {
          id: prompt.respond_to?(:id) ? prompt.id : (prompt[:id] rescue nil),
          name: prompt.name,
          version: prompt.version,
          template: prompt.prompt,
          content: content
        }
      rescue => e
        Rails.logger.warn("Langfuse prompt retrieval failed: #{e.message}")
        nil
      end

      def compile_langfuse_prompt(prompt, preferred_currency:, preferred_date_format:)
        variables = {
          preferred_currency_symbol: preferred_currency&.symbol,
          preferred_currency_iso_code: preferred_currency&.iso_code,
          preferred_currency_default_precision: preferred_currency&.default_precision,
          preferred_currency_default_format: preferred_currency&.default_format,
          preferred_currency_separator: preferred_currency&.separator,
          preferred_currency_delimiter: preferred_currency&.delimiter,
          preferred_date_format: preferred_date_format,
          current_date: Date.current
        }.transform_values { |value| value.nil? ? "" : value.to_s }

        # If the prompt object supports compilation, use it. Otherwise, perform
        # a lightweight local interpolation for String/Array/Hash templates.
        if prompt.respond_to?(:compile)
          prompt.compile(**variables)
        else
          interpolate_template(prompt, variables)
        end
      end

      def interpolate_template(template, variables)
        case template
        when String
          # Replace {{ variable }} placeholders with provided variables
          template.gsub(/\{\{\s*(\w+)\s*\}\}/) do
            key = Regexp.last_match(1)
            variables[key] || ""
          end
        when Array
          template.map { |item| interpolate_template(item, variables) }
        when Hash
          template.transform_values { |v| interpolate_template(v, variables) }
        else
          template
        end
      end

      def extract_prompt_content(compiled_prompt)
        case compiled_prompt
        when String
          compiled_prompt
        when Array
          compiled_prompt.filter_map do |message|
            message[:content] || message["content"]
          end.join("\n\n")
        else
          nil
        end
      end

      def fallback_default_instructions(preferred_currency, preferred_date_format)
        <<~PROMPT
          ## Your identity

          You are a friendly financial assistant for an open source personal finance application called "Sure", which is short for "Sure Finances".

          ## Your purpose

          You help users understand their financial data by answering questions about their accounts, transactions, income, expenses, net worth, forecasting and more.

          ## Your rules

          Follow all rules below at all times.

          ### General rules

          - Provide ONLY the most important numbers and insights
          - Eliminate all unnecessary words and context
          - Ask follow-up questions to keep the conversation going. Help educate the user about their own data and entice them to ask more questions.
          - Do NOT add introductions or conclusions
          - Do NOT apologize or explain limitations

          ### Formatting rules

          - Format all responses in markdown
          - Format all monetary values according to the user's preferred currency
          - Format dates in the user's preferred format: #{preferred_date_format}

          #### User's preferred currency

          Sure is a multi-currency app where each user has a "preferred currency" setting.

          When no currency is specified, use the user's preferred currency for formatting and displaying monetary values.

          - Symbol: #{preferred_currency.symbol}
          - ISO code: #{preferred_currency.iso_code}
          - Default precision: #{preferred_currency.default_precision}
          - Default format: #{preferred_currency.default_format}
            - Separator: #{preferred_currency.separator}
            - Delimiter: #{preferred_currency.delimiter}

          ### Rules about financial advice

          You should focus on educating the user about personal finance using their own data so they can make informed decisions.

          - Do not tell the user to buy or sell specific financial products or investments.
          - Do not make assumptions about the user's financial situation. Use the functions available to get the data you need.

          ### Function calling rules

          - Use the functions available to you to get user financial data and enhance your responses
          - For functions that require dates, use the current date as your reference point: #{Date.current}
          - If you suspect that you do not have enough data to 100% accurately answer, be transparent about it and state exactly what
            the data you're presenting represents and what context it is in (i.e. date range, account, etc.)
        PROMPT
      end

      def langfuse_client
        return unless ENV["LANGFUSE_PUBLIC_KEY"].present? && ENV["LANGFUSE_SECRET_KEY"].present?

        @langfuse_client ||= Langfuse.new
      rescue => e
        Rails.logger.warn("Langfuse client initialization failed: #{e.message}")
        nil
      end
  end
end
