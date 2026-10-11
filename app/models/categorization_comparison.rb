# One transaction categorized twice, by the provider in use and by the one that
# is not. Recorded by Family::AutoCategorizer when shadow mode samples a run;
# only the applied provider's answer reaches the transaction.
#
# `shadow_confidence` is null unless the shadow provider reports one, which the
# LLM providers never do.
class CategorizationComparison < ApplicationRecord
  belongs_to :family
  # Not named `transaction`: ActiveRecord already defines that method, and an
  # association of that name raises on load.
  belongs_to :categorized_transaction,
             class_name: "Transaction",
             foreign_key: :transaction_id,
             optional: true,
             inverse_of: false

  validates :applied_provider, :shadow_provider, presence: true

  scope :disagreements, -> { where(agreed: false) }
  scope :chronological, -> { order(:created_at) }

  # Share of sampled transactions where the two providers picked the same
  # category. Both answering "no category" counts as agreement.
  def self.agreement_rate
    total = count
    return nil if total.zero?

    (where(agreed: true).count.to_f / total * 100).round(2)
  end
end
