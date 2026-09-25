module Assistant
  Error = Class.new(StandardError)

  REGISTRY = {
    "builtin" => Assistant::Builtin,
    "external" => Assistant::External
  }.freeze

  # Tools for users who opted into preview features in Settings -> Preferences.
  #
  # Statement Vault + provenance tools back the wealth agent-harness workflow
  # documented in docs/llm-guides/wealth-agent-harness.md. GetValuations is the
  # read pair for RecordValuation; GetInsights reads the Insights feed, which is
  # itself preview-gated app-wide.
  #
  # The bills tools back the preview-gated Bills subsystem.
  PREVIEW_FUNCTION_CLASSES = [
    Function::UploadAccountStatement,
    Function::ListAccountStatements,
    Function::GetAccountStatement,
    Function::GetStatementCoverage,
    Function::RecordValuation,
    Function::GetValuations,
    Function::GetInsights,
    # Bills: the whole subsystem is preview-gated, so its tools ride the same
    # per-user flag as the surfaces they operate on. Each tool additionally
    # re-checks the family's recurring feature gate and the user's
    # account-access scope itself.
    Function::GetBills,
    Function::GetBillDetails,
    Function::GetPaycheckPlan,
    Function::GetBillAudit,
    Function::CreateBill,
    Function::UpdateBill,
    Function::RecordBillPayment
  ].freeze

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

    # Shared baseline for builtin chat and MCP. MCP-only destructive tools are
    # appended in mcp_function_classes so they are not exposed to the builtin
    # assistant; pass the user to keep preview tools out of the default surface.
    def function_classes(user = nil)
      classes = [
        Function::GetTransactions,
        Function::GetRecurringTransactions,
        Function::GetAccounts,
        Function::GetHoldings,
        Function::GetBalanceSheet,
        Function::GetIncomeStatement,
        Function::GetBudget,
        Function::ImportBankStatement,
        Function::SearchFamilyFiles,
        Function::CreateGoal,
        Function::GetTags,
        Function::CreateTag,
        Function::UpdateTag,
        Function::GetCategories,
        Function::CreateCategory,
        Function::UpdateCategory,
        Function::GetMerchants,
        Function::CreateTransaction,
        Function::UpdateTransaction,
        Function::UpdateBudget
      ]

      classes += PREVIEW_FUNCTION_CLASSES if user&.preview_features_enabled?
      classes
    end

    def mcp_function_classes(user = nil)
      function_classes(user) + [
        Function::GetAccountTypes,
        Function::GetTransfers,
        Function::GetGoals,
        Function::CreateAccount,
        Function::UpdateAccount,
        Function::DeleteAccount,
        Function::DeleteTransaction,
        Function::CreateTransfer,
        Function::UpdateTransfer,
        Function::DeleteTransfer,
        Function::UpdateGoal,
        Function::DeleteGoal,
        Function::DeleteTag,
        Function::DeleteCategory
      ]
    end

    private

      def implementation_for(chat)
        raise Error, "chat is required" if chat.blank?
        type = ENV["ASSISTANT_TYPE"].presence || chat.user&.family&.assistant_type.presence || "builtin"
        REGISTRY.fetch(type) { REGISTRY["builtin"] }
      end
  end
end
