module Assistant::Configurable
  extend ActiveSupport::Concern

  class_methods do
    def config_for(chat)
      family = chat.user.family
      preferred_currency = Money::Currency.new(family.currency)
      preferred_date_format = family.date_format

      if chat.user.ui_layout_intro?
        instructions_config = intro_instructions_config(preferred_currency, preferred_date_format)
        { instructions: instructions_config[:content], instructions_prompt: instructions_config[:prompt], functions: [] }
      else
        instructions_config = default_instructions(preferred_currency, preferred_date_format)
        { instructions: instructions_config[:content], instructions_prompt: instructions_config[:prompt], functions: default_functions }
      end
    end

    private
      def intro_instructions_config(preferred_currency, preferred_date_format)
        langfuse_intro = langfuse_intro_instructions(preferred_currency, preferred_date_format)
        if langfuse_intro.present?
          { content: langfuse_intro[:content], prompt: langfuse_intro }
        else
          content = fallback_intro_instructions(preferred_currency, preferred_date_format)
          { content: content, prompt: { name: "intro_instructions", version: 0, template: nil, content: content } }
        end
      end

      def langfuse_intro_instructions(preferred_currency, preferred_date_format)
        fetch_langfuse_prompt("intro_instructions",
          preferred_currency_symbol: preferred_currency.symbol,
          preferred_currency_iso_code: preferred_currency.iso_code,
          preferred_date_format: preferred_date_format,
          current_date: Date.current
        )
      end

      def fallback_intro_instructions(preferred_currency, preferred_date_format)
        <<~PROMPT
          ## Your identity

          You are Sure, a warm and curious financial guide welcoming a new household to the Sure personal finance application.

          ## Your purpose

          Host an introductory conversation that helps you understand the user's stage of life, financial responsibilities, and near-term priorities so future guidance feels personal and relevant.

          ## Conversation approach

          - Ask one thoughtful question at a time and tailor follow-ups based on what the user shares.
          - Reflect key details back to the user to confirm understanding.
          - Keep responses concise, friendly, and free of filler phrases.
          - If the user requests detailed analytics, let them know the dashboard experience will cover it soon and guide them back to sharing context.

          ## Information to uncover

          - Household composition and stage of life milestones (education, career, retirement, dependents, caregiving, etc.).
          - Primary financial goals, concerns, and timelines.
          - Notable upcoming events or obligations.

          ## Formatting guidelines

          - Use markdown for any lists or emphasis.
          - When money or timeframes are discussed, format currency with #{preferred_currency.symbol} (#{preferred_currency.iso_code}) and dates using #{preferred_date_format}.
          - Do not call external tools or functions.
        PROMPT
      end

      def default_functions
        Assistant.function_classes
      end

      def default_instructions(preferred_currency, preferred_date_format)
        langfuse_instructions = langfuse_default_instructions(preferred_currency, preferred_date_format)

        if langfuse_instructions.present?
          { content: langfuse_instructions[:content], prompt: langfuse_instructions }
        else
          content = fallback_default_instructions(preferred_currency, preferred_date_format)
          { content: content, prompt: { name: "default_instructions", version: 0, template: nil, content: content } }
        end
      end

      def langfuse_default_instructions(preferred_currency, preferred_date_format)
        fetch_langfuse_prompt("default_instructions",
          preferred_currency_symbol: preferred_currency.symbol,
          preferred_currency_iso_code: preferred_currency.iso_code,
          preferred_currency_default_precision: preferred_currency.default_precision,
          preferred_currency_default_format: preferred_currency.default_format,
          preferred_currency_separator: preferred_currency.separator,
          preferred_currency_delimiter: preferred_currency.delimiter,
          preferred_date_format: preferred_date_format,
          current_date: Date.current
        )
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

      def fetch_langfuse_prompt(name, compile_params)
        return unless langfuse_client

        prompt = langfuse_client.get_prompt(name)
        compiled_prompt = prompt.compile(**compile_params)

        content = case compiled_prompt
        when String
          compiled_prompt
        when Array
          compiled_prompt.filter_map { |message| message[:content] }.join("\n\n")
        else
          nil
        end

        return if content.blank?

        template = prompt.respond_to?(:prompt) ? prompt.prompt : (prompt.respond_to?(:template) ? prompt.template : nil)
        { name: prompt.name, version: prompt.version, template: template, content: content }
      rescue => e
        Rails.logger.warn("Langfuse prompt retrieval failed (#{name}): #{e.message}")
        nil
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
