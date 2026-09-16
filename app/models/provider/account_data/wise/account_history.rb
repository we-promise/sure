# Derives overlap behavior from retained rows, not from financial entries or a
# claim that the source history has already been imported completely.
class Provider::AccountData::Wise::AccountHistory
  FORMAT = "wise-account-history/v1".freeze
  MAX_ACCOUNTS = 500
  MAX_ARCHIVE_BYTES = 32 * 1024 * 1024
  MAX_TRANSACTION_ROWS = 50_000

  def self.build(connection:, observed_at:, external_accounts: nil)
    new(connection).build(observed_at: observed_at, external_accounts: external_accounts)
  end

  def self.live_input(connection:)
    new(connection).live_input
  end

  def initialize(connection)
    @connection = connection
    unless connection.persisted? && connection.provider_key == "wise"
      raise Provider::AccountData::StaleWriter, "Wise history belongs to another connection"
    end
    @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "wise")
  end

  def live_input
    freeze_value(
      "item" => reader.item_descriptor,
      "accounts" => accounts.filter_map do |external|
        descriptor = reader.account_descriptor(external)
        next unless descriptor
        link, financial = binding_records(external)
        [ external.id, {
          "source" => descriptor, "external_id" => external.external_id,
          "identity_namespace" => external.identity_namespace, "currency" => external.currency,
          "link" => link&.attributes&.slice(*Copier::RETAINED_LINK_COLUMNS),
          "financial_context" => financial&.attributes&.slice(*Copier::RETAINED_FINANCIAL_CONTEXT_COLUMNS)
        } ]
      end.to_h)
  end

  def build(observed_at:, external_accounts: nil)
    item = reader.item
    @archive_bytes = item&.byte_size.to_i
    @transaction_rows = 0
    check_bounds!
    if item && item.attributes.fetch("profile_id").to_s != connection.settings.fetch("profile_id").to_s
      raise Provider::AccountData::StaleWriter, "Wise retained profile changed"
    end
    policies = accounts(external_accounts).filter_map do |external|
      retained = reader.account(external)
      next unless retained
      raise Provider::AccountData::StaleWriter, "Wise account has no retained profile" unless item
      @archive_bytes += retained.byte_size
      check_bounds!
      binding_records(external)
      disposition = Provider::AccountData::RetainedAccountBinding.classify!(retained: retained, external_account: external)
      values = retained.attributes
      unless values.fetch("wise_item_id") == item.attributes.fetch("id") &&
          values.fetch("balance_id").to_s == external.external_id && values.fetch("currency") == external.currency
        raise Provider::AccountData::StaleWriter, "Wise retained account identity changed"
      end
      payload = values.fetch("raw_payload")
      raise ArgumentError unless payload.nil? || payload.is_a?(Hash)
      balance_type = payload&.fetch("type", nil) == "SAVINGS" ? "SAVINGS" : "STANDARD"
      policy = derive_policy(values.fetch("raw_transactions_payload"))
      # The archive still proves this remote source, but its overlap policy was
      # captured for the removed financial owner. Keep fresh unlinked fetching
      # independent of that owner's historical transfer/statement decisions.
      next if disposition == :detached
      provenance = { "item" => item.context, "account" => retained.context }
      if promotion = Provider::AccountData::Wise::StatementHistory.capture(external_account: external, observed_at: observed_at)
        @archive_bytes += promotion.byte_size
        check_bounds!
        policy["has_statement_history"] = true
        provenance["statement_history"] = promotion.receipt
      end
      [ external.external_id, {
        "external_account_id" => external.id, "identity_namespace" => external.identity_namespace,
        "currency" => external.currency, "balance_type" => balance_type,
        "policy" => policy, "provenance" => provenance
      } ]
    end.to_h
    freeze_value("format" => FORMAT, "connection_id" => connection.id, "family_id" => connection.family_id,
      "profile_id" => connection.settings.fetch("profile_id").to_s, "accounts" => policies)
  rescue KeyError, ArgumentError, TypeError, NoMethodError
    raise Provider::AccountData::InvalidResponse, "Wise retained history cannot establish an overlap policy", cause: nil
  end

  private
    Copier = Provider::AccountData::MigrationCopier
    attr_reader :connection, :reader

    def accounts(provided = nil)
      rows = provided || connection.external_accounts.where(family_id: connection.family_id).order(:id).limit(MAX_ACCOUNTS + 1).to_a
      if rows.size > MAX_ACCOUNTS
        raise Provider::AccountData::IncompletePage, "Wise retained account history exceeds its read bound"
      end
      ids = rows.map(&:external_id)
      unless rows.all? { |external| external.provider_connection_id == connection.id && external.family_id == connection.family_id } &&
          ids.all?(&:present?) && ids.uniq.size == ids.size
        raise Provider::AccountData::StaleWriter, "Wise retained account selection is ambiguous"
      end
      rows
    end

    def binding_records(external)
      link = external.account_provider
      financial = external.current_account
      unless (!link && !financial) || (link && financial && link.account_id == financial.id &&
          link.family_id == connection.family_id && link.external_account_id == external.id &&
          link.provider_key == "wise" && financial.family_id == connection.family_id)
        raise Provider::AccountData::StaleWriter, "Wise account linkage changed"
      end
      [ link, financial ]
    end

    def derive_policy(payload)
      return empty_policy if payload.nil?
      raise ArgumentError unless payload.is_a?(Array)
      @transaction_rows += payload.size
      check_bounds!
      legacy_dates = []
      has_statement = false
      payload.each do |row|
        raise ArgumentError unless row.is_a?(Hash) && row.keys.all? { |key| key.is_a?(String) }
        if row["wise_statement"].present?
          has_statement = true
        elsif !Provider::AccountData::Wise::ACTIVITY_TYPES.include?(row["type"])
          # Missing/ambiguous dates were ignored by the legacy importer. They
          # cannot prove a safe cutoff for a new writer, so require disposition.
          legacy_dates << legacy_date(row["created"] || row["createdOn"] || row["date"])
        end
      end
      { "legacy_transfer_cutoff" => legacy_dates.min&.iso8601,
        "has_legacy_history" => legacy_dates.any?, "has_statement_history" => has_statement }
    end

    def legacy_date(value)
      raise ArgumentError unless value.is_a?(String)
      if value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value)
      elsif value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/)
        Date.iso8601(value[0, 10]) # Reject dates Time.iso8601 might normalize.
        Time.iso8601(value).to_date # Preserve the source offset's calendar date.
      else
        raise ArgumentError
      end
    end

    def empty_policy
      { "legacy_transfer_cutoff" => nil, "has_legacy_history" => false, "has_statement_history" => false }
    end

    def check_bounds!
      if @archive_bytes > MAX_ARCHIVE_BYTES || @transaction_rows > MAX_TRANSACTION_ROWS
        raise Provider::AccountData::IncompletePage, "Wise retained account history exceeds its read bound"
      end
    end

    def freeze_value(value)
      Provider::AccountData::MigrationManifest.copy_value(value)
    end
end
