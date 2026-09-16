require "set"
require "time"

# Per-account first-read bounds, not proof of coverage or a cache importer.
# The cutover caller must first finish its fresh copy and financial identity
# sweeps, retaining the exclusive item permit and financial row locks throughout.
class Provider::AccountData::Brex::CutoverHistory
  class Conflict < Provider::AccountData::StaleWriter; end
  Adapter = Provider::AccountData::Brex

  MAX_ACCOUNTS = 100
  MAX_RECORDS = 10_000
  MAX_BYTES = 32 * 1024 * 1024
  MAX_IDENTITY_BYTES = 1024 * 1024
  Result = Data.define(:account_starts)
  # Replay the original inventory through the real native aggregate without a
  # provider client, request, or a second interpretation of company-card money.
  Inventory = Data.define(:cash, :cards) do
    def get_cash_accounts_page(cursor:)
      { items: cash, next_cursor: nil }
    end

    def get_card_accounts_page(cursor:)
      { items: cards, next_cursor: nil }
    end
  end
  private_constant :Inventory

  def initialize(item:, connection:, family:)
    unless item.is_a?(BrexItem) && item.persisted? && connection.is_a?(ProviderConnection) && connection.persisted? &&
        family.is_a?(Family) && family.persisted?
      raise ArgumentError, "Brex history verification requires persisted ownership"
    end
    @item_id, @connection_id, @family_id = item.id, connection.id, family.id
  end

  def verify!
    raise ArgumentError, "Brex history verification requires the final cutover transaction" if ApplicationRecord.connection.open_transactions.zero?

    ApplicationRecord.uncached do
      @record_count, @archive_bytes = 0, 0
      load_context!
      @default_start = Time.current.getutc.to_date - 90.days
      @completed_at = Sync.where(syncable_type: "BrexItem", syncable_id: item.id, status: "completed")
        .order(created_at: :desc, id: :desc).pick(:completed_at)
      @account_starts = {}
      @history_proof = Provider::AccountData::MigrationHistoryProof.new(connection: connection, control: control,
        family_id: @family_id, source: "brex", max_bytes: MAX_BYTES, max_identity_bytes: MAX_IDENTITY_BYTES)
      verify_accounts!
      Result.new(account_starts: Provider::AccountData::MigrationManifest.copy_value(@account_starts)).freeze
    end
  rescue ActiveRecord::RecordNotFound, ActiveRecord::SoleRecordExceeded, KeyError, TypeError,
      Provider::AccountData::InvalidResponse, Ingestion::LegacyIdentityEvidence::InvalidEvidence,
      Provider::AccountData::MigrationHistoryProof::Conflict
    raise Conflict, "Brex cached history requires exact retained financial provenance", cause: nil
  end

  private
    attr_reader :item, :connection, :control, :reader

    def load_context!
      item_scope = BrexItem.where(id: @item_id, family_id: @family_id)
      @item = item_scope.where("COALESCE(octet_length(raw_payload::text), 0) <= ?", MAX_BYTES).first!
      Provider::AccountData::LegacyWriterFence.assert_exclusive!(item)
      @control = ProviderMigrationControl.find_by!(legacy_type: "BrexItem", legacy_id: item.id,
        family_id: @family_id, provider_key: "brex", provider_connection_id: @connection_id)
      @connection = ProviderConnection.find_by!(id: @connection_id, family_id: @family_id, provider_key: "brex")
      unless control.quiescing? && control.writer_epoch.zero? && control.lease_owner.nil? &&
          connection.disabled? && connection.writer_epoch.zero? && connection.lease_owner.nil? &&
          !item.scheduled_for_deletion? && !connection.scheduled_for_deletion?
        raise Conflict, "Brex history requires the original disabled quiesced ownership"
      end
      @reader = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: "brex")
      original = reader.item
      unless original && original.attributes["sync_start_date"] == item.sync_start_date &&
          original.attributes["raw_payload"] == item.raw_payload && connection.sync_start_date == item.sync_start_date&.to_date
        raise Conflict, "Brex history configuration changed after copying"
      end
      @archive_bytes += original.byte_size
      raise Conflict, "Brex history exceeds its retained archive bound" if @archive_bytes > MAX_BYTES
      @normalizer = Provider::AccountData::Brex.new(client: nil, timezone: Family.find(@family_id).timezone)
      verify_inventory!
    end

    def verify_inventory!
      payload = item.raw_payload
      unless payload.is_a?(Hash) && %w[accounts cash_accounts card_accounts].all? { |key| payload[key].is_a?(Array) }
        raise Conflict, "Brex history needs its complete retained account inventory"
      end
      all, cash, cards = payload.values_at("accounts", "cash_accounts", "card_accounts")
      [ all, cash, cards ].each do |rows|
        unless rows.size <= MAX_ACCOUNTS && rows.all? { |row| row.is_a?(Hash) && row["id"].is_a?(String) && row["id"].present? } &&
            rows.map { |row| row["id"] }.uniq.size == rows.size
          raise Conflict, "Brex retained inventory is malformed or exceeds its bound"
        end
        rows.each do |row|
          %w[current_balance available_balance account_limit].each do |field|
            verify_money!(row[field]) unless row[field].nil?
          end
        end
      end
      unless cash.all? { |row| row["account_kind"] == "cash" && row["id"] != Adapter::CARD_ACCOUNT_ID } &&
          cards.all? { |row| row["account_kind"] == "card" && row["id"] != Adapter::CARD_ACCOUNT_ID }
        raise Conflict, "Brex retained inventory has an ambiguous account kind"
      end
      @inventory = all.index_by { |row| row.fetch("id") }
      expected_ids = cash.map { |row| row.fetch("id") } + (cards.any? ? [ Adapter::CARD_ACCOUNT_ID ] : [])
      unless @inventory.keys.sort == expected_ids.sort && cash.all? { |row| @inventory[row.fetch("id")] == row }
        raise Conflict, "Brex retained inventory omitted or replaced an account"
      end
      if cards.any?
        aggregate = @inventory.fetch(Adapter::CARD_ACCOUNT_ID)
        unless aggregate["account_kind"] == "card" && aggregate["raw_card_accounts"] == cards && aggregate["card_accounts_count"] == cards.size
          raise Conflict, "Brex retained cards require their original company aggregate"
        end
      end

      adapter = Adapter.new(client: Inventory.new(cash: cash, cards: cards), timezone: Family.find(@family_id).timezone)
      cash_page = adapter.list_accounts
      card_page = adapter.list_accounts(cursor: cash_page.next_cursor)
      @normalized_inventory = (cash_page.records + card_page.records).index_by { |record| record[:external_id] }
      unless card_page.complete? && @normalized_inventory.keys.sort == expected_ids.sort && all.all? { |raw|
          @normalizer.normalize_legacy_account(raw).attributes == @normalized_inventory.fetch(raw.fetch("id")).attributes
        }
        raise Conflict, "Brex retained inventory differs from native aggregation"
      end
    end

    def verify_accounts!
      ids = BrexAccount.where(brex_item_id: item.id).order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id)
      raise Conflict, "Brex history exceeds its account bound" if ids.size > MAX_ACCOUNTS
      unless BrexAccount.where(id: ids).pluck(:account_id).sort == @inventory.keys.sort
        raise Conflict, "Brex account inventory has an unapplied or omitted source"
      end
      mappings = control.provider_migration_mappings.where(role: "external_account").order(:id).limit(MAX_ACCOUNTS + 1).to_a
      unless mappings.size == ids.size && mappings.map(&:legacy_id).sort == ids &&
          mappings.all? { |mapping| mapping.legacy_type == "BrexAccount" && mapping.family_id == @family_id }
        raise Conflict, "Brex history account inventory changed"
      end
      if connection.external_accounts.where.not(id: mappings.map(&:external_account_id)).exists?
        raise Conflict, "Brex history contains an uncopied external account"
      end

      # Ciphertext preflight precedes loading any raw cache; repeat the predicate
      # on the materializing SELECT so concurrent growth cannot evade this cap.
      size_sql = "COALESCE(octet_length(raw_transactions_payload::text), 0) + COALESCE(octet_length(raw_payload::text), 0)"
      stored_bytes = BrexAccount.where(id: ids).sum(Arel.sql(size_sql))
      raise Conflict, "Brex history exceeds its stored cache bound" if stored_bytes > MAX_BYTES
      Ingestion::LegacyIdentityEvidence.with_validation_cache do
        mappings.each do |mapping|
          verify_account!(mapping, size_sql)
        end
      end
    end

    def verify_account!(mapping, size_sql)
      external = connection.external_accounts.find_by!(id: mapping.external_account_id, family_id: @family_id, provider_key: "brex")
      links = AccountProvider.where("external_account_id = :external OR (provider_type = 'BrexAccount' AND provider_id = :source)",
        external: external.id, source: mapping.legacy_id).limit(2).to_a
      raise Conflict, "Brex history has ambiguous account ownership" if links.size > 1
      link = links.first
      account = link && Account.where(id: link.account_id, family_id: @family_id).lock("FOR UPDATE NOWAIT").first!
      if link && (link.provider_type != "BrexAccount" || link.provider_id != mapping.legacy_id ||
          link.external_account_id != external.id || link.family_id != @family_id || link.provider_key != "brex" ||
          !%w[active draft disabled].include?(account.status))
        raise Conflict, "Brex history account binding changed"
      end
      source = BrexAccount.where(id: mapping.legacy_id, brex_item_id: item.id).where("#{size_sql} <= ?", MAX_BYTES)
        .select(:id, :brex_item_id, :account_id, :currency, :created_at, :raw_transactions_payload, :raw_payload,
          :account_kind, :current_balance, :available_balance, :account_limit, :name, :account_status).lock("FOR UPDATE NOWAIT").first!
      retained = reader.account(external)
      raise Conflict, "Brex history has no retained account" unless retained
      @archive_bytes += retained.byte_size
      raise Conflict, "Brex history exceeds its retained archive bound" if @archive_bytes > MAX_BYTES
      Provider::AccountData::MigrationCopier.verify_account_binding!(archive: retained.archive, link: link, financial: account)
      raw = source.raw_transactions_payload
      unless retained.attributes["raw_transactions_payload"] == raw && retained.attributes["created_at"] == source.created_at &&
          source.account_id == external.external_id && external.sync_start_date.nil? &&
          %w[raw_payload account_kind currency current_balance available_balance account_limit name account_status].all? { |key| retained.attributes[key] == source[key] }
        raise Conflict, "Brex history differs from its verified original cache"
      end
      verify_snapshot!(source, external)
      # Nil is an unfetched discovery source, allowed only while unlinked. It is
      # not evidence of a successful empty financial transaction fetch.
      raise Conflict, "Brex linked account has no transaction snapshot" if raw.nil? && account
      raw = [] if raw.nil?
      raise Conflict, "Brex transaction cache is malformed" unless raw.is_a?(Array)
      @record_count += raw.size
      raise Conflict, "Brex history exceeds its transaction bound" if @record_count > MAX_RECORDS
      # The old importer ignored item.sync_start_date. Native cutover deliberately
      # honors that copied user setting as a floor. Without it, preserve Brex's
      # account-creation bound for an empty cache and item-success overlap only
      # for a nonempty cache. A sibling's older history never widens this account.
      configured_start = item.sync_start_date&.to_date
      baseline = if raw.any?
        @completed_at ? @completed_at.getutc.to_date - 7.days : @default_start
      else
        [ source.created_at.getutc.to_date - 7.days, @default_start ].max
      end
      start = configured_start || baseline

      seen = Set.new
      raw.each do |data|
        raise Conflict, "Brex transaction cache contains an unknown row" unless data.is_a?(Hash)
        data = data.with_indifferent_access
        verify_money!(data[:amount])
        record = @normalizer.normalize_legacy_transaction(data,
          account: { external_id: source.account_id, currency: source.currency, metadata: { account_kind: source.account_kind } })
        raise Conflict, "Brex transaction cache contains repeated identities" unless seen.add?(record[:external_id])
        dates = data.values_at(:initiated_at_date, :posted_at_date).compact
        raise Conflict, "Brex transaction cache has no original date" if dates.empty?
        cached_start = dates.map { |date| lower_date!(date) }.min
        start = [ start, cached_start ].min unless configured_start
        raise Conflict, "Link or explicitly reconcile cached Brex history before cutover" unless account
        verify_identity!(record, mapping, external, link, account)
      end
      @account_starts[external.id] = start
    rescue Provider::AccountData::MigrationCopier::Conflict
      raise Conflict, "Brex history copy-time account ownership changed", cause: nil
    end

    def verify_snapshot!(source, external)
      record = @normalized_inventory.fetch(source.account_id)
      metadata = record[:metadata].with_indifferent_access
      expected_limit = metadata[:account_limit]&.to_d
      unless source.raw_payload == @inventory.fetch(source.account_id) && source.account_kind == metadata[:account_kind] &&
          source.currency == record[:currency] && external.currency == source.currency &&
          source.current_balance == record[:balance] && source.available_balance == record[:available_balance] &&
          source.account_limit == expected_limit && source.name == record[:name] && source.account_status == metadata[:account_status]
        raise Conflict, "Brex retained account snapshot was not applied exactly"
      end
    end

    def verify_money!(value)
      unless value.is_a?(Hash) && value.key?("amount") && value["currency"].is_a?(String) && value["currency"].present?
        raise Conflict, "Brex retained money requires explicit minor units and currency"
      end
      Money::Currency.new(value.fetch("currency"))
    rescue Money::Currency::UnknownCurrencyError
      raise Conflict, "Brex retained money has an unknown currency", cause: nil
    end

    def verify_identity!(record, mapping, external, link, account)
      @history_proof.verify_transaction!(record: record, mapping: mapping, external: external, link: link, account: account) do |row, identity|
        cached_version_disposed?(record, row, identity)
      end
    end

    def cached_version_disposed?(record, row, identity)
      return false unless identity["role"] == "current" && identity["pending"] == false && record[:pending] == false

      # Compare the original captured financial values, never current user edits.
      # Overrides predating bootstrap cannot be distinguished from a failed cache
      # update and conservatively require review rather than an inferred import.
      snapshot = Provider::AccountData::MigrationValue.decode(row.fetch("financial_snapshot"))
      original, transaction = snapshot.values_at("entry", "entryable")
      metadata = record[:metadata].with_indifferent_access
      %w[amount currency date name].all? { |key| original[key] == record[key.to_sym] } &&
        original["notes"] == metadata[:notes] &&
        transaction.fetch("extra").is_a?(Hash) && transaction.fetch("extra")["brex"] == metadata.fetch(:extra).fetch("brex")
    end

    def lower_date!(value)
      return value if value.instance_of?(Date)
      return value.to_time.getutc.to_date if value.is_a?(Time) || value.is_a?(DateTime)
      raise ArgumentError unless value.is_a?(String) && value.present?
      return Date.iso8601(value) unless value.match?(/[T:]/)
      raise ArgumentError unless value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
      Time.iso8601(value).getutc.to_date
    rescue ArgumentError, RangeError
      raise Conflict, "Brex cached history has an invalid original date", cause: nil
    end
end
