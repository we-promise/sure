module Transaction::Refundable
  extend ActiveSupport::Concern

  included do
    belongs_to :refund_of, class_name: "Transaction", optional: true
    has_many :purchase_refunds, class_name: "Transaction", foreign_key: :refund_of_id, dependent: :nullify, inverse_of: :refund_of

    validate :valid_refund_relationship
  end

  def refundable?
    (standard? || refund? || cc_payment?) && !transfer && entry&.amount&.negative? && !pending? && !entry.split_parent? && !entry.excluded?
  end

  def refundable_purchase?
    standard? && entry&.amount&.positive? && !pending? && !entry.split_parent? && !entry.excluded?
  end

  def refund_linked?
    refund_of_id.present? || purchase_refunds.exists?
  end

  def mark_as_refund!(purchase: nil)
    self.class.transaction do
      # Splitting takes the same transaction lock. Reload both records under
      # deterministic locks so validation never uses pre-lock associations.
      [ self, purchase ].compact.uniq.sort_by { |record| record.id.to_s }.each(&:lock!)
      unless refundable?
        errors.add(:base, :invalid_refund)
        raise ActiveRecord::RecordInvalid, self
      end

      self.extra = extra.merge("refund" => { "previous_kind" => kind }) unless refund?
      self.kind = "refund"
      self.refund_of = purchase
      self.category = purchase.category if purchase
      save!
      lock_attr!(:kind)
      lock_attr!(:refund_of_id)
      lock_attr!(:category_id) if purchase
      entry.mark_user_modified!
    end
  end

  def clear_refund!
    with_lock do
      previous_kind = extra.dig("refund", "previous_kind").presence_in(%w[standard cc_payment]) || "standard"
      update!(kind: previous_kind, refund_of: nil, extra: extra.except("refund"))
      lock_attr!(:kind)
      lock_attr!(:refund_of_id)
      entry.mark_user_modified!
    end
  end

  # Callers rendering purchase details pass only refunds accessible to the viewer.
  # Missing dated rates deliberately raise Money::ConversionError.
  def purchase_net_cost_money(refunds: purchase_refunds.includes(:entry))
    refunds.reduce(entry.amount_money) do |net, refund|
      net + refund.entry.amount_money.exchange_to(entry.currency, date: refund.entry.date)
    end
  end

  private
    def valid_refund_relationship
      if refund? && entry && !entry.amount.negative?
        errors.add(:base, :invalid_refund)
      end

      if refund_of
        unless refund? && refund_of != self && refund_of.refundable_purchase? &&
            entry&.account&.family_id == refund_of.entry.account.family_id
          errors.add(:refund_of, :invalid)
        end
      end

      if kind_changed? && persisted? && !standard? && purchase_refunds.exists?
        errors.add(:base, :refund_links_present)
      end
    end
end
