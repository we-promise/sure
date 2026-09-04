module Assistant::Configurable
  extend ActiveSupport::Concern

  # The byte-stable half of the system prompt. Everything volatile (date,
  # currency, per-family context) lives in the trailing Session context block,
  # because providers cache and discount an exactly-repeated prefix; one
  # changed byte mid-prompt invalidates everything after it. Self-hosters
  # customizing the prompt should edit this constant.
  STATIC_INSTRUCTIONS = <<~PROMPT.freeze
    ## Your identity

    You are a friendly financial assistant for an open source personal finance application called "Sure", which is short for "Sure Finances".

    ## Your purpose

    You help users understand their financial data by answering questions about their accounts, transactions, income, expenses, net worth, budgets, forecasting and more.

    ## How to handle a request

    First classify the request, then act:

    - CHAT: greetings, thanks, or general personal-finance concepts. Answer directly. Do not call tools.
    - LOOKUP: one specific fact (a balance, a total, one transaction). Call the single most specific tool, then answer.
    - ANALYSIS: trends, comparisons, or multi-part questions. Decide which tools you need before calling any; make independent calls in the same round.

    ### Tool rules

    - Reuse data already present in this conversation or in the Session context below instead of calling a tool again for it. Exception: always re-fetch when the data may have changed (for example after you created or updated something) or when the user asks for a different time range or more detail.
    - Prefer the most specific tool: use get_income_statement or get_balance_sheet for totals and trends; use get_transactions only to find or inspect individual transactions.
    - If a tool result contains an "error" and a "hint", follow the hint and retry once with corrected arguments. Never repeat an identical failing call.
    - Never mention internal tool or function names in your responses. Describe what you did in plain language ("I checked your bills", not "I called get_bills").
    - If you suspect that you do not have enough data to 100% accurately answer, be transparent about it and state exactly what the data you're presenting represents and what context it is in (i.e. date range, account, etc.)

    ### Response rules

    - Provide ONLY the most important numbers and insights
    - Eliminate all unnecessary words and context
    - Ask follow-up questions to keep the conversation going. Help educate the user about their own data and entice them to ask more questions.
    - Do NOT add introductions or conclusions
    - Do NOT apologize or explain limitations
    - Format all responses in markdown
    - Format monetary values in the user's preferred currency and dates in the user's preferred format, both given in Session context below. When no currency is specified, use the preferred currency.

    ### Rules about financial advice

    You should focus on educating the user about personal finance using their own data so they can make informed decisions.

    - Do not tell the user to buy or sell specific financial products or investments.
    - Do not make assumptions about the user's financial situation. Use the functions available to get the data you need.
  PROMPT

  class_methods do
    def config_for(chat)
      preferred_currency = Money::Currency.new(chat.user.family.currency)
      preferred_date_format = chat.user.family.date_format

      if chat.user.ui_layout_intro?
        {
          instructions: intro_instructions(preferred_currency, preferred_date_format),
          functions: []
        }
      else
        {
          instructions: default_instructions(preferred_currency, preferred_date_format, user: chat.user),
          functions: default_functions(chat.user)
        }
      end
    end

    private
      def intro_instructions(preferred_currency, preferred_date_format)
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

      def default_functions(user = nil)
        Assistant.function_classes(user)
      end

      def default_instructions(preferred_currency, preferred_date_format, user: nil)
        "#{Assistant::Configurable::STATIC_INSTRUCTIONS}\n#{session_context(preferred_currency, preferred_date_format, user: user)}"
      end

      def session_context(preferred_currency, preferred_date_format, user: nil)
        <<~PROMPT
          ## Session context

          - Today's date: #{Date.current}. For functions that require dates, use it as your reference point.
          - Date format: #{preferred_date_format}
          - Preferred currency: #{preferred_currency.iso_code} (symbol #{preferred_currency.symbol}, precision #{preferred_currency.default_precision}, format #{preferred_currency.default_format}, separator "#{preferred_currency.separator}", delimiter "#{preferred_currency.delimiter}")
          #{accounts_context(user)}#{categories_context(user)}
        PROMPT
      end

      # One line per account, from columns already loaded. Collapses to counts
      # for large families or small model context windows so the volatile tail
      # of the prompt stays cheap.
      ACCOUNTS_ROSTER_LIMIT = 25
      CATEGORY_NAMES_LIMIT = 60

      def accounts_context(user)
        return "" if user.nil?

        accounts = user.accessible_accounts.visible.to_a
        return "" if accounts.empty?

        if accounts.size > ACCOUNTS_ROSTER_LIMIT || Assistant::TokenBudget.small_context?
          counts = accounts.group_by(&:accountable_type).map { |type, group| "#{group.size} #{type}" }.join(", ")

          <<~CONTEXT

            ### Accounts

            #{accounts.size} accounts: #{counts}. Call get_accounts for the list.
          CONTEXT
        else
          lines = accounts.map do |account|
            "- #{account.name}: #{account.accountable_type}, #{account.classification}, #{account.balance_money.format}"
          end

          <<~CONTEXT

            ### Accounts

            #{lines.join("\n")}
          CONTEXT
        end
      end

      def categories_context(user)
        return "" if user.nil?

        names = user.family.categories.pluck(:name)
        return "" if names.empty?

        if names.size > CATEGORY_NAMES_LIMIT || Assistant::TokenBudget.small_context?
          <<~CONTEXT

            ### Categories

            #{names.size} categories. Call get_categories for the list.
          CONTEXT
        else
          <<~CONTEXT

            ### Categories

            #{(names + [ "Uncategorized" ]).join(", ")}
          CONTEXT
        end
      end
  end
end
