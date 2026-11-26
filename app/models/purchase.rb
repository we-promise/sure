# Something a family member bought, read from a forwarded order email or a scanned receipt, with
# its line items and, once known, the bank transaction that paid for it.
class Purchase < ApplicationRecord
  # Days after the order date in which a bank transaction counts as its payment.
  MATCH_WINDOW_DAYS = 3
  # Cash on delivery is paid when the parcel arrives and recorded by hand.
  COD_MATCH_WINDOW_DAYS = 14
  # After this many days without a payment the user is told the purchase is unmatched.
  DEADLINE_DAYS = 14
  # Matching keeps trying this long after the order date, for statements imported monthly.
  MATCH_HORIZON_DAYS = 90
  OPEN_STATUSES = %w[awaiting_payment needs_matching unmatched].freeze

  belongs_to :family
  belongs_to :user
  # Not `:transaction`: that name would shadow ActiveRecord::Base#transaction.
  belongs_to :linked_transaction, class_name: "Transaction", foreign_key: :transaction_id, optional: true, inverse_of: :purchase
  belongs_to :receipt_scan, optional: true

  has_many :items, -> { order(:position) }, class_name: "PurchaseItem", dependent: :destroy, inverse_of: :purchase
  has_one_attached :original_email
  # The receipt or invoice files of an emailed purchase; they also go onto its linked transaction.
  has_many_attached :receipt_files

  enum :source, { email: "email", receipt: "receipt" }, validate: true
  enum :status, {
    processing: "processing",
    awaiting_payment: "awaiting_payment",
    needs_matching: "needs_matching",
    matched: "matched",
    unmatched: "unmatched",
    dismissed: "dismissed",
    rejected: "rejected",
    failed: "failed"
  }, validate: true
  enum :payment_method, {
    card: "card",
    blik: "blik",
    transfer: "transfer",
    cash_on_delivery: "cash_on_delivery",
    cash: "cash",
    installments: "installments",
    other: "other",
    unknown: "unknown"
  }, prefix: :paid_by, validate: true

  LinkError = Class.new(StandardError)

  scope :to_match, -> { where(status: OPEN_STATUSES) }

  # Purchases a user may see: their own, and others' that are linked to a transaction on an
  # account the user can access.
  scope :visible_to, ->(user) {
    where(user_id: user.id).or(
      where(transaction_id: Transaction.joins(:entry).where(entries: { account_id: Account.accessible_by(user).select(:id) }).select(:id))
    )
  }

  # Its own user, or someone who may change the transaction it is linked to.
  def changeable_by?(user)
    return true if user_id == user.id
    return false unless linked_transaction

    Account.annotatable_by(user).where(id: linked_transaction.entry.account_id).exists?
  end

  def match_window_days
    paid_by_cash_on_delivery? ? COD_MATCH_WINDOW_DAYS : MATCH_WINDOW_DAYS
  end

  def link!(entry, manual: false)
    Purchase::Linker.new(self).link!(entry, manual:)
  end

  def unlink!
    Purchase::Linker.new(self).unlink!
  end

  # The receipt's files the user may open, by the rule blob access applies: a scanned receipt's
  # follow the scan's account; an emailed receipt's, once on the linked transaction, follow that
  # transaction's account (for the owner too), and before that belong to the owner.
  def receipt_documents_for(user)
    account = linked_transaction&.entry&.account
    allowed =
      if receipt_scan
        receipt_scan.family_id == family_id && receipt_scan.account.shared_with?(user)
      elsif account
        account.shared_with?(user)
      else
        user_id == user.id
      end
    return [] unless allowed

    (receipt_scan ? receipt_scan.files : receipt_files).attachments.includes(:blob).to_a
  end

  # One of this purchase's amounts as Money, or nil when there's no amount or its currency is one
  # Money doesn't know (the read flags it as unknown_currency).
  def money(amount)
    return if amount.nil?

    Money.new(amount, currency.presence || family.currency)
  rescue Money::Currency::UnknownCurrencyError
    nil
  end

  # The amount formatted in the purchase's currency, or as read ("12.5 ZL") when Money can't.
  def amount_text(amount, formatter: :format.to_proc)
    return "—" if amount.nil?

    (money = money(amount)) ? formatter.call(money) : "#{amount.to_d.to_s("F")} #{currency}"
  end

  def categories_held_back?
    Purchase::Linker.new(self).categories_held_back?
  end

  def apply_categories!(user)
    Purchase::Linker.new(self).apply_categories!(user)
  end

  def dismiss!
    update!(status: :dismissed, match_candidate_entry_ids: [])
  end

  # Looks for the payment and records what was found. Returns the match kind.
  def apply_match!
    result = Purchase::Matcher.new(self).result
    case result.kind
    when :single
      link!(result.entries.first)
    when :ambiguous
      update!(status: :needs_matching, match_candidate_entry_ids: result.entries.map(&:id))
    when :none
      update!(status: :awaiting_payment, match_candidate_entry_ids: []) unless unmatched?
    when :skipped
      update!(status: :unmatched, match_candidate_entry_ids: [])
    end
    result.kind
  end

  # A failed order email that can be read again: one whose original was never stored has
  # nothing to read.
  def reprocessable? = failed? && email? && original_email.attached?

  # Starts reading a failed order email again. Under the purchase's lock, so two clicks start
  # one run. Returns whether it started one.
  def reprocess!
    with_lock do
      next false unless reprocessable?

      update!(status: :processing, error: nil)
      Ai::GenerationRun.enqueue(:extract_purchase, family:, ids: [ id ])
    end
  end

  # Re-checks the stored AI read against the current total rules, without calling the AI again.
  # Clears an items_mismatch the rules now accept; returns whether it did.
  def revalidate_items_total!
    raw = ai_metadata["raw_output"]
    return false unless raw.is_a?(Hash) && review_reasons.any? { _1["reason"] == "items_mismatch" }

    problems = Purchase::Validator.new(Purchase::Validator.extraction_from(raw), family:).problems
    return false if problems.any? { _1["reason"] == "items_mismatch" }

    update!(
      review_reasons: review_reasons.reject { _1["reason"] == "items_mismatch" },
      ai_metadata: ai_metadata.merge("validation" => Array(ai_metadata["validation"]).reject { _1["reason"] == "items_mismatch" })
    )
    true
  end

  # The shop's domain for its logo, unless it is the domain the user forwards from: a manual
  # forward we couldn't unwrap only shows the forwarder.
  def shop_domain(domain)
    return if domain.blank?

    own = user.purchase_inbox_routes.sender.pluck(:value).map { Purchase::EmailText.registrable_domain(_1) }
    domain unless own.include?(domain)
  end

  # Fills merchant_domain from the stored email without calling the AI.
  def backfill_merchant_domain!
    return false unless email? && merchant_domain.blank? && original_email.attached?

    domain = shop_domain(Purchase::EmailText.new(Mail.new(original_email.download)).call.original_from_domain)
    domain.present? && update!(merchant_domain: domain)
  end

  def flag!(reason_key, **details)
    update!(review_reasons: review_reasons + [ { "reason" => reason_key.to_s, **details.deep_stringify_keys } ])
  end

  # Called when the linked transaction is about to be deleted: an email purchase goes back to
  # waiting for its payment, a receipt purchase stays as history without a transaction.
  # The linked transaction is going away. Its receipt files may already have moved to the bank's
  # booked copy of it, where nothing links them to this purchase any more: take them off every
  # transaction, so a later link attaches them afresh.
  def release_transaction!
    transaction do
      ActiveStorage::Attachment.where(record_type: "Transaction", name: "attachments", blob_id: receipt_files.blobs.select(:id)).delete_all
      update!(
        transaction_id: nil,
        matched_at: nil,
        status: email? ? :awaiting_payment : :unmatched
      )
    end
  end
end
