class Transaction < ApplicationRecord
  include Entryable, Transferable, Ruleable, Splittable

  belongs_to :category, optional: true
  belongs_to :merchant, optional: true

  has_many :taggings, as: :taggable, dependent: :destroy
  has_many :tags, through: :taggings

  # File attachments (receipts, invoices, etc.) using Active Storage
  # Supports images (JPEG, PNG, GIF, WebP) and PDFs up to 10MB each
  # Maximum 10 attachments per transaction, family-scoped access
  has_many_attached :attachments do |attachable|
    attachable.variant :thumbnail, resize_to_limit: [ 150, 150 ]
  end

  # Attachment validation constants
  MAX_ATTACHMENTS_PER_TRANSACTION = 10
  MAX_ATTACHMENT_SIZE = 10.megabytes
  ALLOWED_CONTENT_TYPES = %w[
    image/jpeg image/jpg image/png image/gif image/webp
    application/pdf
  ].freeze

  validate :validate_attachments, if: -> { attachments.attached? }

  accepts_nested_attributes_for :taggings, allow_destroy: true

  after_save :clear_merchant_unlinked_association, if: :merchant_id_previously_changed?

  # Accessors for exchange_rate stored in extra jsonb field
  def exchange_rate
    extra&.dig("exchange_rate")
  end

  def exchange_rate=(value)
    if value.blank?
      self.extra = (extra || {}).merge("exchange_rate" => nil, "exchange_rate_invalid" => false)
    else
      begin
        normalized_value = Float(value)
        raise ArgumentError unless normalized_value.finite?

        self.extra = (extra || {}).merge("exchange_rate" => normalized_value, "exchange_rate_invalid" => false)
      rescue ArgumentError, TypeError
        # Store the raw value for validation error reporting
        self.extra = (extra || {}).merge("exchange_rate" => value, "exchange_rate_invalid" => true)
      end
    end
  end

  validate :exchange_rate_must_be_valid

  private

    def exchange_rate_must_be_valid
      if extra&.dig("exchange_rate_invalid")
        errors.add(:exchange_rate, "must be a number")
      elsif exchange_rate.present?
        numeric_rate = Float(exchange_rate) rescue nil
        if numeric_rate.nil? || !numeric_rate.finite? || numeric_rate <= 0
          errors.add(:exchange_rate, "must be greater than 0")
        end
      end
    end

  public

  enum :kind, {
    standard: "standard", # A regular transaction, included in budget analytics
    funds_movement: "funds_movement", # Movement of funds between accounts, excluded from budget analytics
    cc_payment: "cc_payment", # A CC payment, excluded from budget analytics (CC payments offset the sum of expense transactions)
    loan_payment: "loan_payment", # A payment to a Loan account, treated as an expense in budgets
    one_time: "one_time", # A one-time expense/income, excluded from budget analytics
    investment_contribution: "investment_contribution" # Transfer to investment/crypto account, treated as an expense in budgets
  }

  # All kinds where money moves between accounts (transfer? returns true).
  # Used for search filters, rule conditions, and UI display.
  TRANSFER_KINDS = %w[funds_movement cc_payment loan_payment investment_contribution].freeze

  # Kinds excluded from budget/income-statement analytics.
  # loan_payment and investment_contribution are intentionally NOT here —
  # they represent real cash outflow from a budgeting perspective.
  BUDGET_EXCLUDED_KINDS = %w[funds_movement one_time cc_payment].freeze

  # All valid investment activity labels (for UI dropdown)
  ACTIVITY_LABELS = [
    "Buy", "Sell", "Sweep In", "Sweep Out", "Dividend", "Reinvestment",
    "Interest", "Fee", "Transfer", "Contribution", "Withdrawal", "Exchange", "Other"
  ].freeze

  # Internal movement labels that should be excluded from budget (auto cash management)
  INTERNAL_MOVEMENT_LABELS = [ "Transfer", "Sweep In", "Sweep Out", "Exchange" ].freeze

  # Providers that support pending transaction flags
  PENDING_PROVIDERS = %w[simplefin plaid lunchflow enable_banking].freeze

  # Pre-computed SQL fragment for subqueries that check if a transaction (aliased as "t") is pending.
  # Stored as a constant so static analysis can verify it contains no user input.
  PENDING_CHECK_SQL = PENDING_PROVIDERS
    .map { |p| "(t.extra -> '#{p}' ->> 'pending')::boolean = true" }
    .join(" OR ")
    .freeze

  # Pending transaction scopes - filter based on provider pending flags in extra JSONB
  # Works with any provider that stores pending status in extra["provider_name"]["pending"]
  scope :pending, -> {
    conditions = PENDING_PROVIDERS.map { |provider| "(transactions.extra -> '#{provider}' ->> 'pending')::boolean = true" }
    where(conditions.join(" OR "))
  }

  scope :excluding_pending, -> {
    conditions = PENDING_PROVIDERS.map { |provider| "(transactions.extra -> '#{provider}' ->> 'pending')::boolean IS DISTINCT FROM true" }
    where(conditions.join(" AND "))
  }

  # SQL snippet for raw queries that must exclude pending transactions.
  # Use in income statements, balance sheets, and raw analytics.
  def self.pending_providers_sql(table_alias = "t")
    PENDING_PROVIDERS.map do |provider|
      "AND (#{table_alias}.extra -> '#{provider}' ->> 'pending')::boolean IS DISTINCT FROM true"
    end.join("\n")
  end

  # Family-scoped query for Enrichable#clear_ai_cache
  def self.family_scope(family)
    joins(entry: :account).where(accounts: { family_id: family.id })
  end

  # Overarching grouping method for all transfer-type transactions
  def transfer?
    TRANSFER_KINDS.include?(kind)
  end

  def set_category!(category)
    if category.is_a?(String)
      category = entry.account.family.categories.find_or_create_by!(
        name: category
      )
    end

    update!(category: category)
  end

  def pending?
    extra_data = extra.is_a?(Hash) ? extra : {}
    PENDING_PROVIDERS.any? do |provider|
      ActiveModel::Type::Boolean.new.cast(extra_data.dig(provider, "pending"))
    end
  rescue StandardError
    false
  end

  def activity_security_id
    extra&.dig("security_id").presence || extra&.dig("security", "id").presence
  end

  def activity_security
    security_id = activity_security_id.to_s
    return @activity_security = nil if security_id.blank?
    return @activity_security if defined?(@activity_security_id) && @activity_security_id == security_id

    @activity_security_id = security_id
    @activity_security = Security.find_by(id: security_id)
  end

  def set_preloaded_activity_security(security)
    @activity_security_id = security&.id&.to_s
    @activity_security = security
  end

  # Potential duplicate matching methods
  # These help users review and resolve fuzzy-matched pending/posted pairs

  def has_potential_duplicate?
    potential_posted_match_data.present? && !potential_duplicate_dismissed?
  end

  def potential_duplicate_entry
    return nil unless has_potential_duplicate?
    Entry.find_by(id: potential_posted_match_data["entry_id"])
  end

  def potential_duplicate_reason
    potential_posted_match_data&.dig("reason")
  end

  def potential_duplicate_confidence
    potential_posted_match_data&.dig("confidence") || "medium"
  end

  def low_confidence_duplicate?
    potential_duplicate_confidence == "low"
  end

  def potential_duplicate_posted_amount
    potential_posted_match_data&.dig("posted_amount")&.to_d
  end

  def potential_duplicate_dismissed?
    potential_posted_match_data&.dig("dismissed") == true
  end

  # Merge this pending transaction with its suggested posted match.
  # The pending entry is destroyed; the posted entry survives with attributes inherited from both sides.
  # Attribute inheritance: Date + Category from pending, Name + Merchant from posted (booked).
  def merge_with_duplicate!
    return false unless pending?
    return false unless has_potential_duplicate?

    posted_entry = potential_duplicate_entry
    return false unless posted_entry

    pending_entry = entry

    # Guard: cross-account merges are never valid
    if posted_entry.account_id != pending_entry.account_id
      Rails.logger.warn("merge_with_duplicate! rejected: posted_entry #{posted_entry.id} belongs to different account than pending entry #{pending_entry.id}")
      return false
    end

    pending_entry_id = pending_entry.id
    merge_succeeded = false

    ApplicationRecord.transaction(requires_new: true) do
      # Row-level locks prevent concurrent merges on the same pair of entries.
      # If a concurrent request already destroyed the pending entry, lock! raises
      # RecordNotFound — treat that as an idempotent success.
      begin
        pending_entry.lock!
      rescue ActiveRecord::RecordNotFound
        Rails.logger.info("Pending entry #{pending_entry_id} already destroyed (concurrent merge), skipping")
        return true
      end

      begin
        posted_entry.lock!
      rescue ActiveRecord::RecordNotFound
        Rails.logger.info("Posted entry #{posted_entry.id} deleted concurrently; aborting merge")
        raise ActiveRecord::Rollback
      end

      # Capture after lock! (which reloads) to guarantee DB-fresh values and avoid
      # stale in-memory cached associations (e.g., loaded via touch: true).
      external_id        = pending_entry.external_id
      pending_entry_date = pending_entry.date

      # Batch all changes to the surviving posted Transaction into a single update!
      # to avoid firing after_save callbacks twice on the same row.
      # Lock the Transaction row so concurrent merges into the same posted entry
      # cannot race on reading/writing extra (e.g., the manual_merge array).
      posted_tx = posted_entry.entryable
      posted_tx.lock! if posted_tx.is_a?(Transaction)
      if posted_tx.is_a?(Transaction)
        tx_attrs = {}

        # Merge metadata — always written so the sync engine can skip re-importing.
        # Stored as an array so multiple pending entries merged into the same posted
        # transaction each preserve their external_id for future sync exclusion.
        # Legacy records written as a plain Hash are migrated to a single-element array
        # on first append, maintaining backward compatibility.
        if external_id.present?
          new_record = {
            "merged_from_entry_id"    => pending_entry_id,
            "merged_from_external_id" => external_id,
            "merged_at"               => Time.current.iso8601,
            "source"                  => pending_entry.source
          }
          prior = case posted_tx.extra["manual_merge"]
          when Array then posted_tx.extra["manual_merge"]
          when Hash  then [ posted_tx.extra["manual_merge"] ]
          else []
          end
          tx_attrs[:extra] = posted_tx.extra.merge("manual_merge" => prior + [ new_record ])
        end

        # Attribute inheritance — only when the posted entry is not already user-protected.
        unless posted_entry.protected_from_sync?
          pending_transaction = pending_entry.entryable
          if pending_transaction.is_a?(Transaction) && pending_transaction.category_id.present?
            tx_attrs[:category_id] = pending_transaction.category_id
          end
        end

        posted_tx.update!(tx_attrs) if tx_attrs.any?
      end

      # Date inheritance on the Entry row — separate from the Transaction update above.
      unless posted_entry.protected_from_sync?
        # Date: pending dates reflect actual transaction initiation time
        posted_entry.update!(date: pending_entry_date) if posted_entry.date != pending_entry_date
        # Name + Merchant intentionally NOT inherited — booked values are canonical
      end

      # Lock the posted entry so future syncs cannot overwrite the merged state
      posted_entry.mark_user_modified!

      Rails.logger.info("User merged pending entry #{pending_entry_id} (ext: #{external_id}) into posted entry #{posted_entry.id}")
      pending_entry.destroy!
      merge_succeeded = true
    end

    merge_succeeded
  end

  # Dismiss the duplicate suggestion - user says these are NOT the same transaction
  def dismiss_duplicate_suggestion!
    return false unless potential_posted_match_data.present?

    updated_extra = (extra || {}).deep_dup
    updated_extra["potential_posted_match"]["dismissed"] = true
    update!(extra: updated_extra)

    Rails.logger.info("User dismissed duplicate suggestion for entry #{entry.id}")
    true
  end

  # Clear the duplicate suggestion entirely
  def clear_duplicate_suggestion!
    return false unless potential_posted_match_data.present?

    updated_extra = (extra || {}).deep_dup
    updated_extra.delete("potential_posted_match")
    update!(extra: updated_extra)
    true
  end

  # Find potential posted transactions that might be duplicates of this pending transaction
  # Returns entries (not transactions) for UI consistency with transfer matcher
  # Lists recent posted transactions from the same account for manual merging
  def pending_duplicate_candidates(limit: 20, offset: 0)
    return Entry.none unless pending? && entry.present?

    account = entry.account
    currency = entry.currency

    # Find recent posted transactions from the same account
    conditions = PENDING_PROVIDERS.map { |provider| "(transactions.extra -> '#{provider}' ->> 'pending')::boolean IS NOT TRUE" }

    account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where.not(id: entry.id)
      .where(currency: currency)
      .where(conditions.join(" AND "))
      .order(date: :desc, created_at: :desc)
      .limit(limit)
      .offset(offset)
  end

  private

    def validate_attachments
      # Check attachment count limit
      if attachments.size > MAX_ATTACHMENTS_PER_TRANSACTION
        errors.add(:attachments, :too_many, max: MAX_ATTACHMENTS_PER_TRANSACTION)
      end

      # Validate each attachment
      attachments.each_with_index do |attachment, index|
        # Check file size
        if attachment.byte_size > MAX_ATTACHMENT_SIZE
          errors.add(:attachments, :too_large, index: index + 1, max_mb: MAX_ATTACHMENT_SIZE / 1.megabyte)
        end

        # Check content type
        unless ALLOWED_CONTENT_TYPES.include?(attachment.content_type)
          errors.add(:attachments, :invalid_format, index: index + 1, file_format: attachment.content_type)
        end
      end
    end

    def potential_posted_match_data
      return nil unless extra.is_a?(Hash)
      extra["potential_posted_match"]
    end

    def clear_merchant_unlinked_association
      return unless merchant_id.present? && merchant.is_a?(ProviderMerchant)

      family = entry&.account&.family
      return unless family

      FamilyMerchantAssociation.where(family: family, merchant: merchant).delete_all
    end
end
