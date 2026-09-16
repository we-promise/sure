# Captures every financial input that can change the projection. At application
# time the writer takes row locks and compares this state again before writing.
class Ingestion::HistoricalBalances::Inputs
  MAX_RECORDS = 250_000
  ACCOUNT_COLUMNS = %w[id family_id currency balance cash_balance accountable_type created_at updated_at].freeze
  ENTRY_COLUMNS = %w[id date amount currency entryable_type entryable_id source excluded user_modified import_locked locked_attributes
    reconciled_at reconciled_by_statement_id created_at updated_at].freeze

  def self.capture(account, lock: false)
    new(account, lock: lock).capture
  end

  def initialize(account, lock:)
    @account, @lock = account, lock
  end

  def capture
    entries = read(@account.entries).map { |entry| entry.attributes.slice(*ENTRY_COLUMNS) }
    trades = read_entryables(Trade, entries)
      .map { |trade| trade.attributes.slice("id", "qty", "extra", "updated_at") }
    valuations = read_entryables(Valuation, entries)
      .map { |valuation| valuation.attributes.slice("id", "kind", "locked_attributes", "updated_at") }
    balances = read(@account.balances).map(&:attributes)
    { "account" => @account.attributes.slice(*ACCOUNT_COLUMNS), "entries" => entries, "trades" => trades,
      "valuations" => valuations, "balances" => balances }
  end

  def self.protected_valuation?(entry, valuation)
    entry.values_at("excluded", "user_modified", "import_locked").include?(true) || entry["reconciled_at"].present? || entry["reconciled_by_statement_id"].present? ||
      %w[amount date currency].any? { |key| entry.fetch("locked_attributes", {})[key].present? } ||
      valuation.fetch("locked_attributes", {}).values.any?(&:present?)
  end

  private
    def read_entryables(model, entries)
      identifiers = entries.select { |entry| entry["entryable_type"] == model.name }.map { |entry| entry.fetch("entryable_id") }.uniq.sort
      # Bound each bind list independently of the account-size limit, while
      # retaining stable row-lock order across batches.
      identifiers.each_slice(1_000).flat_map { |ids| read(model.where(id: ids)) }
    end

    def read(scope)
      scope = scope.order(:id).limit(MAX_RECORDS + 1)
      scope = scope.lock if @lock
      rows = scope.to_a
      raise Provider::AccountData::IncompletePage, "Historical balance inputs exceed the reviewed account size" if rows.size > MAX_RECORDS
      rows
    end
end
