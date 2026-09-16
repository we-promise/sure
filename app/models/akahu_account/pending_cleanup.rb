require "digest"

# An in-memory receipt joins one complete pending response to the exact cache
# commit and original pending financial rows. It cannot survive a released
# provider permit or authorize deletion from an old cache alone.
class AkahuAccount::PendingCleanup
  Access = AkahuItem::LegacyAccess
  Fence = Access::Fence
  MAX_RECORDS = 20_000
  MAX_CANDIDATES = 1_000
  MAX_BYTES = 16.megabytes
  Receipt = Data.define(:permit, :database, :source_id, :item_id, :family_id, :account_id,
    :source_context, :transport_context, :source_version, :stored_digest, :pending_ids, :pending_bases, :candidates) do
    def inspect = "#<AkahuAccount::PendingCleanup::Receipt>"

    def issued_for?(current_permit, current_database, current_source_id)
      permit.equal?(current_permit) && database.equal?(current_database) &&
        permit.fetch(:akahu_pending_inventories, {})[current_source_id].equal?(self)
    end

    private :permit, :database
  end
  private_constant :Receipt

  def self.capture(source:, pending_rows:, source_context:, transport_context:)
    unless ApplicationRecord.connection.transaction_open?
      raise Fence::InvalidSource, "Akahu pending inventory requires its cache publication transaction"
    end
    permit = current_permit!(source)
    Access.verify_source!(source, source_context)
    Access.verify_transport!(source.akahu_item, transport_context)
    account = source.current_account
    return nil unless account
    unless pending_rows.is_a?(Array) && pending_rows.size <= MAX_RECORDS && pending_rows.to_json.bytesize <= MAX_BYTES
      raise Fence::OwnershipChanged, "Akahu pending inventory exceeds its validation limits"
    end
    cache = source.raw_transactions_payload
    unless cache.is_a?(Array) && cache.size <= MAX_RECORDS && cache.to_json.bytesize <= MAX_BYTES && cache.all? { |raw| raw.is_a?(Hash) }
      raise Fence::OwnershipChanged, "Akahu pending inventory has an invalid cache"
    end
    normalizer = Provider::AccountData::Akahu.new(client: nil, timezone: source.akahu_item.family.timezone)
    normalize = lambda do |raw|
      normalizer.normalize_legacy_transaction(raw, account: { external_id: source.account_id, currency: source.currency })
    end
    records = pending_rows.map { |raw| normalize.call(raw) }
    unless records.all? { |record| record[:pending] } &&
        cache.select { |raw| AkahuEntry::Processor.pending?(raw) }.map { |raw| normalize.call(raw).attributes } == records.map(&:attributes)
      raise Fence::OwnershipChanged, "Akahu pending inventory does not describe its committed cache"
    end
    ids, bases = records.partition { |record| !record[:metadata][:identity_policy] }
    ids = ids.map { |record| record[:external_id] }.uniq.sort
    bases = bases.map { |record| record[:external_id] }.uniq.sort
    rows = pending_entries(account.id).order("entries.id").limit(MAX_CANDIDATES + 1)
      .lock("FOR UPDATE OF entries, transactions NOWAIT").pluck(:id, :entryable_id,
        Arel.sql("entries.xmin::text"), Arel.sql("entries.ctid::text"),
        Arel.sql("transactions.xmin::text"), Arel.sql("transactions.ctid::text"))
    raise Fence::OwnershipChanged, "Akahu pending cleanup exceeds its row limit" if rows.size > MAX_CANDIDATES
    version, stored_digest = source_stamp(source)
    receipt = Receipt.new(permit: permit, database: ApplicationRecord.connection, source_id: source.id.dup.freeze, item_id: source.akahu_item_id.dup.freeze,
      family_id: account.family_id.dup.freeze, account_id: account.id.dup.freeze,
      source_context: source_context.dup.freeze, transport_context: transport_context.dup.freeze,
      source_version: Provider::AccountData::MigrationManifest.copy_value(version), stored_digest: stored_digest.freeze,
      pending_ids: Provider::AccountData::MigrationManifest.copy_value(ids),
      pending_bases: Provider::AccountData::MigrationManifest.copy_value(bases),
      candidates: Provider::AccountData::MigrationManifest.copy_value(rows)).freeze
    # Data#with can clone a receipt. Only the exact issued object can consume
    # this inventory, and a later capture supersedes the source's earlier one.
    (permit[:akahu_pending_inventories] ||= {})[source.id] = receipt
    receipt
  rescue Provider::AccountData::InvalidResponse
    raise Fence::OwnershipChanged, "Akahu pending inventory is not complete valid source data", cause: nil
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Akahu pending inventory is being changed", cause: nil
  end

  def initialize(source, receipt:)
    @source, @receipt = source, receipt
  end

  def call
    unless @receipt.is_a?(Receipt) && @receipt.source_id == @source.id &&
        @receipt.issued_for?(self.class.send(:current_permit!, @source), ApplicationRecord.connection, @source.id)
      raise Fence::OwnershipChanged, "Akahu pending cleanup requires its original uninterrupted inventory permit"
    end
    Access.with_account(@source) do |current|
      account = current.current_account
      unless account && account.id == @receipt.account_id && account.family_id == @receipt.family_id && current.akahu_item_id == @receipt.item_id
        raise Fence::OwnershipChanged, "Akahu pending inventory account changed"
      end
      Access.with_publication(current, expected_account: account, resource: "transactions") do |fresh, financial|
        verify_receipt!(fresh)
        candidates = @receipt.candidates.index_by(&:first)
        entries = financial.entries.where(id: candidates.keys).order(:id).lock("FOR UPDATE NOWAIT").to_a
        transactions = Transaction.where(id: entries.select(&:transaction?).map(&:entryable_id)).order(:id)
          .lock("FOR UPDATE NOWAIT").index_by(&:id)
        deleted = 0
        entries.each do |entry|
          next unless entry.transaction?
          entry.association(:entryable).target = transactions[entry.entryable_id]
          next unless eligible?(entry) && !observed?(entry.external_id)
          actual = self.class.send(:pending_entries, financial.id).where(id: entry.id).pluck(:id, :entryable_id,
            Arel.sql("entries.xmin::text"), Arel.sql("entries.ctid::text"),
            Arel.sql("transactions.xmin::text"), Arel.sql("transactions.ctid::text")).first
          unless actual == candidates.fetch(entry.id)
            raise Fence::OwnershipChanged, "Akahu pending financial identity changed after inventory capture"
          end
          entry.destroy!
          deleted += 1
        end
        deleted
      end
    end
  rescue ActiveRecord::LockWaitTimeout
    raise Fence::Busy, "Akahu pending entries are being changed; retry the complete inventory", cause: nil
  end

  class << self
    private
      def current_permit!(source)
        held = ActiveSupport::IsolatedExecutionState[Fence::CONTEXT_KEY]
        unless held && held[:database].equal?(ApplicationRecord.connection) &&
            held.fetch(:members).key?([ "AkahuItem", source.akahu_item_id, source.akahu_item.family_id ])
          raise Fence::OwnershipChanged, "Akahu pending inventory requires an uninterrupted provider permit"
        end
        held
      end

      def pending_entries(account_id)
        Entry.where(account_id: account_id, source: "akahu", entryable_type: "Transaction")
          .where.not(external_id: [ nil, "" ])
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
          .where("transactions.extra -> 'akahu' ->> 'pending' IN (?)", %w[true 1])
      end

      def source_stamp(source)
        # Read actual stored ciphertext, including immediately after an AR save.
        # The size predicate prevents loading an oversized stored value.
        query = AkahuAccount.where(id: source.id, akahu_item_id: source.akahu_item_id)
          .where("octet_length(raw_transactions_payload::text) <= ?", MAX_BYTES)
          .select(Arel.sql("xmin::text, ctid::text, raw_transactions_payload::text AS pending_cleanup_ciphertext"))
        row = ApplicationRecord.uncached { ApplicationRecord.connection.select_rows(query.to_sql).first }
        raise Fence::OwnershipChanged, "Akahu pending cache is missing or exceeds its stored limit" unless row
        [ row.first(2), Digest::SHA256.hexdigest(row.fetch(2)) ]
      end
  end

  private
    def verify_receipt!(source)
      Access.verify_source!(source, @receipt.source_context)
      Access.verify_transport!(source.akahu_item, @receipt.transport_context)
      version, digest = self.class.send(:source_stamp, source)
      unless version == @receipt.source_version && digest == @receipt.stored_digest
        raise Fence::OwnershipChanged, "Akahu pending cache changed after its complete inventory"
      end
    end

    def observed?(id)
      @receipt.pending_ids.include?(id) || @receipt.pending_bases.any? do |base|
        id == base || id.match?(/\A#{Regexp.escape(base)}_[0-9]+\z/)
      end
    end

    def eligible?(entry)
      return false unless entry.source == "akahu" && entry.external_id.to_s.start_with?("akahu_") && entry.transaction
      return false if entry.protected_from_sync? || entry.reconciled? || entry.locked_attributes.present? || entry.transaction.locked_attributes.present?
      return false if entry.parent_entry_id || entry.child_entries.exists? || entry.transaction.transfer_id || entry.transaction.transfer?
      return false if Transfer.where(inflow_transaction_id: entry.entryable_id).or(Transfer.where(outflow_transaction_id: entry.entryable_id)).exists?
      return false if RejectedTransfer.where(inflow_transaction_id: entry.entryable_id).or(RejectedTransfer.where(outflow_transaction_id: entry.entryable_id)).exists?
      return false if GoalPledge.where(matched_transaction_id: entry.entryable_id).exists? || entry.recurring_allocations.exists?
      return false if entry.transaction.attachments.attached?
      return false if Entry.where(entryable_type: "Transaction", entryable_id: entry.entryable_id).where.not(id: entry.id).exists?
      return false if EntrySource.where(entry_id: entry.id).or(EntrySource.where(entry_identity: entry.id)).exists?
      extra = entry.transaction.extra
      return false unless extra.is_a?(Hash) && extra["akahu"].is_a?(Hash)
      return false if (Transaction::PENDING_PROVIDERS - [ "akahu" ]).any? { |provider| extra.key?(provider) }
      ActiveModel::Type::Boolean.new.cast(extra.dig("akahu", "pending")) == true
    end
end
