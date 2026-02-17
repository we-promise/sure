module Assistant::Configurable
  extend ActiveSupport::Concern

  class_methods do
    def config_for(chat)
      preferred_currency = Money::Currency.new(chat.user.family.currency)
      preferred_date_format = chat.user.family.date_format

      interpolation_vars = {
        currency_symbol: preferred_currency.symbol,
        currency_iso_code: preferred_currency.iso_code,
        currency_default_precision: preferred_currency.default_precision,
        currency_default_format: preferred_currency.default_format,
        currency_separator: preferred_currency.separator,
        currency_delimiter: preferred_currency.delimiter,
        date_format: preferred_date_format,
        current_date: Date.current.to_s
      }

      if chat.user.ui_layout_intro?
        template = instructions_config[:intro] || fallback_intro_instructions
        {
          instructions: format(template, interpolation_vars),
          functions: []
        }
      else
        template = instructions_config[:default] || fallback_default_instructions
        {
          instructions: format(template, interpolation_vars),
          functions: default_functions
        }
      end
    end

    private
      def instructions_config
        Rails.configuration.x.assistant.instructions || {}
      end

      def default_functions
        [
          Assistant::Function::GetTransactions,
          Assistant::Function::GetAccounts,
          Assistant::Function::GetHoldings,
          Assistant::Function::GetBalanceSheet,
          Assistant::Function::GetIncomeStatement,
          Assistant::Function::ImportBankStatement,
          Assistant::Function::SearchFamilyFiles
        ]
      end

      def fallback_intro_instructions
        <<~PROMPT
          ## Your identity

          You are Sure, a warm and curious financial guide welcoming a new household to the Sure personal finance application.

          ## Your purpose

          Host an introductory conversation that helps you understand the user's stage of life, financial responsibilities, and near-term priorities so future guidance feels personal and relevant.

          ## Formatting guidelines

          - Use markdown for any lists or emphasis.
          - When money or timeframes are discussed, format currency with %{currency_symbol} (%{currency_iso_code}) and dates using %{date_format}.
          - Do not call external tools or functions.
        PROMPT
      end

      def fallback_default_instructions
        <<~PROMPT
          ## Your identity

          You are a friendly financial assistant for an open source personal finance application called "Sure", which is short for "Sure Finances".

          ## Your purpose

          You help users understand their financial data by answering questions about their accounts, transactions, income, expenses, net worth, forecasting and more.

          ## Formatting rules

          - Format all responses in markdown
          - Format dates in the user's preferred format: %{date_format}
          - Currency symbol: %{currency_symbol} (%{currency_iso_code})

          ## Function calling rules

          - Use the functions available to you to get user financial data and enhance your responses
          - For functions that require dates, use the current date as your reference point: %{current_date}
        PROMPT
      end
  end
end
