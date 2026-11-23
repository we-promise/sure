module Transaction::Refundable
  extend ActiveSupport::Concern

  included do
    belongs_to :refund_of, class_name: "Transaction", optional: true
    has_many :purchase_refunds, class_name: "Transaction", foreign_key: :refund_of_id, dependent: :nullify, inverse_of: :refund_of

    validate :valid_refund_relationship
    after_update :detach_recurring_allocations_after_refund
  end

  def refundable?
    # `transfer` is the matched Transfer record, not `transfer?`. An unpaired
    # cc_payment leg has no Transfer yet and may be corrected to a refund; once
    # matched, the Transfer owns its kind and it is no longer refundable.
    (standard? || refund? || cc_payment?) && !transfer && entry&.amount&.negative? && !pending? && !entry.split_parent? && !entry.excluded?
  end

  def refundable_purchase?
    standard? && !transfer && entry&.amount&.positive? && !pending? && !entry.split_parent? && !entry.excluded?
  end

  def refund_linked?
    refund_of_id.present? || purchase_refunds.exists?
  end

  def mark_as_refund!(purchase: nil)
    self.class.transaction do
      # Splitting takes the same transaction lock. Reload both records under
      # deterministic locks so validation never uses pre-lock associations.
      [ self, purchase ].compact.uniq.sort_by { |record| record.id.to_s }.each(&:lock!)
      # Allocation writes take the occurrence then entry advisory lock. Take
      # the same locks in the same order before changing the classification so
      # a concurrent confirmation cannot create a payment that this refund
      # misses, and the second writer sees the first writer's committed state.
      RecurringTransaction::Allocator.lock_refund_classification!(entry)
      unless refundable?
        errors.add(:base, :invalid_refund)
        raise ActiveRecord::RecordInvalid, self
      end

      self.extra = extra.merge("refund" => { "previous_kind" => kind }) unless refund?
      self.kind = "refund"
      self.refund_of = purchase
      self.category = purchase.category if purchase&.category
      save!
      lock_attr!(:kind)
      lock_attr!(:refund_of_id)
      lock_attr!(:category_id) if purchase&.category
      entry.mark_user_modified!
    end
  end

  def clear_refund!
    with_lock do
      # A second clear may reach here after the first restored the previous
      # kind. with_lock reloads first, so leave that restoration alone.
      return unless refund?

      previous_kind = extra.dig("refund", "previous_kind").presence_in(%w[standard cc_payment]) || "standard"
      update!(kind: previous_kind, refund_of: nil, extra: extra.except("refund"))
      # Undo is still an explicit classification choice; provider enrichment
      # must not replace it on the next sync.
      lock_attr!(:kind)
      lock_attr!(:refund_of_id)
      entry.mark_user_modified!
    end
  end

  # Callers rendering purchase details pass only refunds accessible to the viewer.
  # Missing dated rates deliberately raise Money::ConversionError.
  def purchase_net_cost_money(refunds: purchase_refunds.includes(:entry))
    refunds.reduce(entry.amount_money) do |net, refund|
      converted = if block_given?
        yield refund.entry.amount_money, entry.currency, refund.entry.date
      else
        refund.entry.amount_money.exchange_to(entry.currency, date: refund.entry.date)
      end
      net + converted
    end
  end

  private
    # A refund is not a bill or income payment. Drop confirmed allocations
    # whenever this transaction becomes a refund, not only through the command,
    # so archive imports, sync and direct edits cannot leave a paid total
    # counting it.
    def detach_recurring_allocations_after_refund
      return unless saved_change_to_kind? && refund?

      RecurringTransaction::Allocator.unallocate_entry!(entry) if entry
    end

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
