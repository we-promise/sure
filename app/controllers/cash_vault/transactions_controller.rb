module CashVault
  class TransactionsController < BaseController
    before_action :consume_unlock!

    def index
      @entries = Current.family.entries
        .joins(:account)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
        .where(accounts: { accountable_type: "Depository" })
        .excluding_split_parents
        .preload(:account, entryable: [ :category, :merchant ])
        .reverse_chronological
    end

    private
      def consume_unlock!
        unlocked = ActiveModel::Type::Boolean.new.cast(session.delete(:cash_vault_unlocked))
        redirect_to cash_vault_auth_path unless unlocked
      end
  end
end
