class EnableBankingItem::LegacyAccess < Provider::AccountData::LegacyAccess
  MAX_CACHE_BYTES = 16 * 1024 * 1024
  MAX_ACCOUNTS = 2_000
  def self.provider_key = "enable_banking"

  # A response belongs to the original application AND institution consent.
  # Expiry reconciliation may advance this fingerprint only after publication.
  def self.transport_columns
    %w[id family_id application_id client_certificate country_code authorization_id session_id session_expires_at
      aspsp_id aspsp_name aspsp_required_psu_headers aspsp_maximum_consent_validity aspsp_auth_approach
      aspsp_psu_types psu_type last_psu_ip sync_start_date]
  end

  def self.source_columns
    %w[id enable_banking_item_id uid account_id identification_hashes account_type account_status currency
      current_balance credit_limit treat_balance_as_available_credit name]
  end

  def self.source_context(source)
    assert_stored_source_bound!(source.id) if source.persisted?
    unless [ source.raw_payload, source.raw_transactions_payload ].to_json.bytesize <= MAX_CACHE_BYTES
      raise Fence::InvalidSource, "Enable Banking decoded source cache exceeds its bound"
    end
    super
  end

  def self.with_account(source, operation: :publish, &block)
    assert_stored_source_bound!(source.id) if source.is_a?(EnableBankingAccount) && source.persisted?
    super
  end

  # Count stored bytes before materialization and select exactly those tuples.
  # This bounds inventory loops without holding database locks across transport.
  def self.bounded_sources(scope)
    table = EnableBankingAccount.table_name
    headers = scope.reorder("#{table}.id").limit(MAX_ACCOUNTS + 1).pluck("#{table}.id",
      Arel.sql("#{table}.xmin::text"), Arel.sql("#{table}.ctid::text"), Arel.sql(
        "COALESCE(octet_length(#{table}.raw_payload::text), 0) + COALESCE(octet_length(#{table}.raw_transactions_payload::text), 0)"))
    if headers.size > MAX_ACCOUNTS || headers.sum(&:last) > MAX_CACHE_BYTES
      raise Fence::InvalidSource, "Enable Banking source inventory exceeds its bound"
    end
    return [] if headers.empty?

    tuples = Array.new(headers.size, "(?, ?, ?)").join(", ")
    rows = scope.where("(#{table}.id::text, #{table}.xmin::text, #{table}.ctid::text) IN (VALUES #{tuples})", *headers.flat_map { |row| row.first(3) })
      .reorder("#{table}.id").limit(MAX_ACCOUNTS).to_a
    unless rows.map(&:id) == headers.map(&:first)
      raise Fence::OwnershipChanged, "Enable Banking source inventory changed before capture"
    end
    rows
  end

  def self.assert_stored_source_bound!(id)
    bytes = EnableBankingAccount.where(id: id).pick(Arel.sql(
      "COALESCE(octet_length(raw_payload::text), 0) + COALESCE(octet_length(raw_transactions_payload::text), 0)"))
    raise Fence::OwnershipChanged, "Enable Banking source disappeared" unless bytes
    raise Fence::InvalidSource, "Enable Banking stored source cache exceeds its bound" if bytes > MAX_CACHE_BYTES
  end

  private_class_method :assert_stored_source_bound!
end
