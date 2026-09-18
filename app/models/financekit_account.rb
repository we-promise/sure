class FinancekitAccount < ApplicationRecord
  belongs_to :financekit_item
  belongs_to :financekit_account_lineage
  has_one :account, through: :financekit_account_lineage

  delegate :financekit_transactions, :financekit_balance_observations, to: :financekit_account_lineage

  def self.map!(item, source_id, input)
    Financekit::AccountMapping.new(item, source_id, input).apply!
  end

  def raw_payload
    nil
  end
end
