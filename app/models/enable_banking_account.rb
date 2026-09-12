class EnableBankingAccount < ApplicationRecord
  include CurrencyNormalizable, Encryptable

  # Encrypt raw payloads if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
    # deterministic: true preserves equality lookups (e.g. find_by(iban:)) —
    # the account's own IBAN was previously stored in plaintext here, unlike
    # the other columns on this model.
    # See Account#iban for the deliberate tradeoff this makes (accepted here
    # for the same reason: DB-level uniqueness/lookup can't work otherwise).
    encrypts :iban, deterministic: true
  end

  belongs_to :enable_banking_item

  # New association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true
  validates :uid, presence: true, uniqueness: { scope: :enable_banking_item_id }
  # account_id is not uniquely scoped: uid already enforces one-account-per-identifier per item

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Returns the API account ID (UUID) for Enable Banking API calls
  # The Enable Banking API requires a valid UUID for balance/transaction endpoints
  # Falls back to raw_payload["uid"] for existing accounts that have the wrong account_id stored
  def api_account_id
    # Check if account_id looks like a valid UUID (not an identification_hash)
    if account_id.present? && account_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
      account_id
    else
      # Fall back to raw_payload for existing accounts with incorrect account_id
      raw_payload&.dig("uid") || account_id || uid
    end
  end

  # Map PSD2 cash_account_type codes to user-friendly names
  # Based on ISO 20022 External Cash Account Type codes
  def account_type_display
    return nil unless account_type.present?

    type_mappings = {
      "CACC" => "Current/Checking Account",
      "SVGS" => "Savings Account",
      "CARD" => "Card Account",
      "CRCD" => "Credit Card",
      "LOAN" => "Loan Account",
      "MORT" => "Mortgage Account",
      "ODFT" => "Overdraft Account",
      "CASH" => "Cash Account",
      "TRAN" => "Transacting Account",
      "SALA" => "Salary Account",
      "MOMA" => "Money Market Account",
      "NREX" => "Non-Resident External Account",
      "TAXE" => "Tax Account",
      "TRAS" => "Cash Trading Account",
      "ONDP" => "Overnight Deposit"
    }

    type_mappings[account_type.upcase] || account_type.titleize
  end

  CASH_ACCOUNT_TYPE_MAP = {
    "CACC" => { type: "Depository", subtype: "checking" },
    "SVGS" => { type: "Depository", subtype: "savings" },
    "CARD" => { type: "CreditCard", subtype: "credit_card" },
    "CRCD" => { type: "CreditCard", subtype: "credit_card" },
    "LOAN" => { type: "Loan",       subtype: nil },
    "MORT" => { type: "Loan",       subtype: "mortgage" },
    "ODFT" => { type: "Depository", subtype: "checking" },
    "TRAN" => { type: "Depository", subtype: "checking" },
    "SALA" => { type: "Depository", subtype: "checking" },
    "MOMA" => { type: "Depository", subtype: "savings" },
    "NREX" => { type: "Depository", subtype: "checking" },
    "TAXE" => { type: "Depository", subtype: "checking" },
    "TRAS" => { type: "Depository", subtype: "checking" },
    "ONDP" => { type: "Depository", subtype: "savings" },
    "CASH" => { type: "Depository", subtype: "checking" },
    "OTHR" => nil
  }.freeze

  def suggested_account_type
    CASH_ACCOUNT_TYPE_MAP[account_type&.upcase]&.dig(:type)
  end

  def suggested_subtype
    CASH_ACCOUNT_TYPE_MAP[account_type&.upcase]&.dig(:subtype)
  end

  def upsert_enable_banking_snapshot!(account_snapshot)
    snapshot = account_snapshot.with_indifferent_access

    raw_account_id = snapshot[:account_id]
    account_id_data = if raw_account_id.is_a?(Hash)
      raw_account_id
    elsif raw_account_id.is_a?(Array) && raw_account_id.first.is_a?(Hash)
      raw_account_id.find { |item| item[:iban].present? } || {}
    else
      {}
    end

    credit_limit_amount = snapshot.dig(:credit_limit, :amount)

    update!(
      current_balance: nil,
      # Preserve an established currency when the snapshot omits or mangles it
      # (normalized, so blank/invalid stored values still fall through) —
      # EUR only for records that never had a valid currency. Mirrors the
      # equivalent Lunch Flow fix; PSD2 payloads usually carry currency, so
      # this is parity/safety rather than an observed failure.
      currency: parse_currency(snapshot[:currency]) || parse_currency(currency) || "EUR",
      name: build_account_name(snapshot),
      account_id: snapshot[:uid],
      uid: snapshot[:identification_hash] || snapshot[:uid],
      iban: account_id_data[:iban] || snapshot[:iban],
      account_type: snapshot[:cash_account_type] || snapshot[:account_type],
      account_status: "active",
      provider: "enable_banking",
      product: snapshot[:product],
      credit_limit: parse_decimal_safe(credit_limit_amount),
      identification_hashes: snapshot[:identification_hashes] || [],
      institution_metadata: {
        name: enable_banking_item&.aspsp_name,
        aspsp_name: enable_banking_item&.aspsp_name,
        bic: snapshot.dig(:account_servicer, :bic_fi),
        servicer_name: snapshot.dig(:account_servicer, :name)
      }.compact,
      raw_payload: account_snapshot
    )

    propagate_iban_to_account!
  end

  def upsert_enable_banking_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  # Only fills a blank Account#iban with the provider value, and never a
  # blank the user set deliberately (see Enrichable) -- a plain
  # target.iban.blank? check can't tell "never touched" apart from "user
  # cleared it on purpose", and this must not undo the latter.
  #
  # Public (not called only from #upsert_enable_banking_snapshot!): account
  # discovery runs before the linking AccountProvider exists, so this is a
  # no-op at that point (current_account is nil). EnableBankingItemsController
  # calls this again right after creating the AccountProvider, once there is
  # actually a target to propagate to.
  def propagate_iban_to_account!
    return if iban.blank?

    target = current_account
    return if target.nil?

    # #with_lock reloads target under SELECT FOR UPDATE before the block
    # runs, so a concurrent manual edit that lands between our earlier
    # load of `target` and this write can't be silently clobbered by the
    # sync (a plain `target.iban.present?` check followed by `update` has
    # no such guarantee).
    target.with_lock do
      next if target.iban.present?

      # enrich_attribute no-ops if `iban` is locked (the user explicitly set
      # or cleared it via the account form -- lock_saved_attributes! locks
      # either way), and uses `save` rather than `save!`, so a Rails-level
      # uniqueness validation failure just fails to enrich instead of
      # raising. #with_lock only serializes writers to THIS row though: two
      # different blank-iban accounts in the family can both pass that
      # validation concurrently and then lose at the raw DB unique index on
      # commit, which surfaces as RecordNotUnique -- save doesn't rescue
      # that. Isolated in its own savepoint (same pattern as
      # Account::ProviderImportAdapter#backfill_merchant_iban!): a failed
      # statement would otherwise abort the whole surrounding transaction.
      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          target.enrich_attribute(:iban, iban, source: "enable_banking")
        end

        # enrich_attribute's own "was it modified" return value can't be
        # trusted to reflect a failed save (a Rails quirk in how it derives
        # that from previous_changes), so check the record's errors
        # directly instead. Empty errors covers both a successful write and
        # a locked attribute (an intentional, silent skip -- see the method
        # comment above); errors present means the internal `save` actually
        # attempted and failed (e.g. another account in the family already
        # has this IBAN), which is worth surfacing in the support debug log
        # rather than only a Rails log line.
        if target.errors.any?
          capture_propagation_failure(target, target.errors.full_messages.join(", "))
        end
      rescue ActiveRecord::RecordNotUnique
        # Deliberately not e.message: PostgreSQL's unique-violation DETAIL
        # clause embeds the actual conflicting IBAN value in plaintext,
        # which would defeat the point of encrypting the column at rest by
        # persisting it into an unrelated log table instead.
        capture_propagation_failure(target, "Concurrent iban conflict on the family_id+iban unique index")
      end
    end
  end

  private

    def capture_propagation_failure(target, message)
      DebugLogEntry.capture(
        category: "provider_sync_warning",
        level: "warn",
        message: "Could not propagate IBAN to account: #{message}",
        source: self.class.name,
        provider_key: "enable_banking",
        family: enable_banking_item&.family,
        account: target,
        account_provider: account_provider,
        metadata: { enable_banking_account_id: id, account_id: target.id }
      )
    end

    def build_account_name(snapshot)
      # Try to build a meaningful name from the account data
      raw_account_id = snapshot[:account_id]
      account_id_data = if raw_account_id.is_a?(Hash)
        raw_account_id
      elsif raw_account_id.is_a?(Array) && raw_account_id.first.is_a?(Hash)
        raw_account_id.find { |item| item[:iban].present? } || {}
      else
        {}
      end
      iban = account_id_data[:iban] || snapshot[:iban]

      if snapshot[:name].present?
        snapshot[:name]
      elsif iban.present?
        # Use last 4 digits of IBAN for privacy
        "Account ...#{iban[-4..]}"
      else
        "Enable Banking Account"
      end
  end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for EnableBanking account #{id}, defaulting to EUR")
    end

    def parse_decimal_safe(value)
      return nil if value.blank?
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
end
