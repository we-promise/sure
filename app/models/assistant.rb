module Assistant
  Error = Class.new(StandardError)

  REGISTRY = {
    "builtin" => Assistant::Builtin,
    "external" => Assistant::External
  }.freeze

  class << self
    def for_chat(chat)
      implementation_for(chat).for_chat(chat)
    end

    def config_for(chat)
      raise Error, "chat is required" if chat.blank?
      Assistant::Builtin.config_for(chat)
    end

    def available_types
      REGISTRY.keys
    end

    def function_classes
      [
        Function::GetTransactions,
        Function::GetAccounts,
        Function::GetHoldings,
        Function::GetBalanceSheet,
        Function::GetIncomeStatement,
        Function::ImportBankStatement,
        Function::SearchFamilyFiles
      ]
    end

    private

      def implementation_for(chat)
        raise Error, "chat is required" if chat.blank?
        type = chat.user&.family&.assistant_type.presence || "builtin"
        REGISTRY.fetch(type) { REGISTRY["builtin"] }
      end
  end
end
