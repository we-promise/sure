# frozen_string_literal: true

class WiseAccount < ApplicationRecord
  include Encryptable

  # Kept from the stored snapshot when a new one lacks them: the recipient
  # ids that decide transfer direction (a failed lookup must not flip it)
  # and Sure's own markers on the balance.
  PRESERVED_KEYS = %w[
    recipient_id borderless_account_id recipientId closed_at absent_count statements_coverage name_history prune_cap_bypass
    opening_anchor
  ].freeze

  # First key of the advisory lock that serializes the processing of one
  # balance (#with_processing_lock); the second is a hash of its id.
  PROCESSING_LOCK_NAMESPACE = 4014

  # Processing was asked to run inside a caller's transaction (see
  # #with_processing_lock).
  ProcessingInTransaction = Class.new(StandardError)

  if encryption_ready?
    encrypts :raw_payload
    encrypts :raw_transactions_payload
  end

  belongs_to :wise_item

  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider

  validates :balance_id, :currency, presence: true
  validates :balance_id, uniqueness: { scope: :wise_item_id }

  scope :unlinked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }

  def current_account
    account
  end

  def jar?
    raw_payload&.dig("type") == "SAVINGS"
  end

  # Wise no longer lists the balance (raw_payload "closed_at", one of
  # PRESERVED_KEYS).
  def closed?
    raw_payload.is_a?(Hash) && raw_payload["closed_at"].present?
  end

  # When Sure found the balance closed, as a UTC time, or nil.
  def closed_at
    parse_utc(raw_payload["closed_at"]) if closed?
  end

  # When Wise opened the balance (its creationTime), as a UTC time, or nil.
  def creation_time
    parse_utc(raw_payload["creationTime"]) if raw_payload.is_a?(Hash)
  end

  # The window successful statement fetches for this balance have covered
  # without a gap, as { from:, through: } UTC times (raw_payload
  # "statements_coverage", one of PRESERVED_KEYS), or nil before the first.
  def statements_coverage
    coverage = raw_payload["statements_coverage"] if raw_payload.is_a?(Hash)
    return nil unless coverage.is_a?(Hash)

    from, through = coverage.values_at("from", "through").map { |time| parse_utc(time) }
    { from: from, through: through } if from && through
  end

  # The external ids of the entries whose rows a sync that re-fetched the
  # whole history moved out of this balance's payload, or left booking
  # nothing on it (raw_payload "prune_cap_bypass", one of PRESERVED_KEYS):
  # the stale-entry clean-up may delete these beyond its cap until it has
  # run after a complete import (WiseAccount::Transactions::Processor).
  def prune_cap_bypass_ids
    ids = raw_payload["prune_cap_bypass"] if raw_payload.is_a?(Hash)
    Array(ids).map(&:to_s)
  end

  # Once the clean-up has run after a complete import; taken out of the
  # snapshot as stored now (#locked_raw_payload), so what a sync stored
  # meanwhile stays.
  def spend_prune_cap_bypass!
    return unless raw_payload.is_a?(Hash) && raw_payload.key?("prune_cap_bypass")

    self.class.transaction { update!(raw_payload: locked_raw_payload.except("prune_cap_bypass")) }
  end

  # The opening anchor Sure last set on the balance's account (raw_payload
  # "opening_anchor", one of PRESERVED_KEYS), as { entry_id:, date:,
  # amount: }, or nil before Sure set one.
  def written_opening_anchor
    written = raw_payload["opening_anchor"] if raw_payload.is_a?(Hash)
    return nil unless written.is_a?(Hash)

    { entry_id: written["entry_id"], date: Date.iso8601(written["date"].to_s), amount: written["amount"].to_d }
  rescue ArgumentError
    nil
  end

  # Records an opening anchor entry as Sure just set it, so a later change
  # by a person can be told apart (WiseAccount::Processor). Merged into the
  # snapshot as stored now, under a row lock, so the marks a sync writes
  # meanwhile stay.
  def remember_opening_anchor!(entry)
    written = { "entry_id" => entry.id, "date" => entry.date.iso8601, "amount" => entry.amount.to_d.to_s }
    merge_raw_payload!({ "opening_anchor" => written })
  end

  # The day a balance whose whole history Sure imports starts at 0: the day
  # before Wise opened it, in the family's zone. nil unless the item imports
  # the full history and Wise said when it opened the balance.
  def opening_date
    created = creation_time
    return nil unless created && wise_item.import_all_history?

    created.in_time_zone(wise_item.time_zone).to_date.prev_day
  end

  # Serializes everything that books or deletes this balance's entries, such
  # as an item sync's processing and a balance processed on its own. It is a
  # session-level advisory lock, not a row lock or a transaction: saving an
  # Account locks its owner's users row, so a transaction held across a whole
  # payload would stall every other account save of that user meanwhile.
  # Rows still commit one by one. Re-entrant on the same connection.
  #
  # Never inside a caller's transaction: its rows would not commit one by
  # one, and an error aborting it would make the unlock fail, leaving the
  # lock with the pooled connection, where every later processing of the
  # balance would wait for it for good.
  def with_processing_lock
    if self.class.current_transaction.open?
      raise ProcessingInTransaction, "WiseAccount #{id} must not be processed inside a transaction"
    end

    connection = self.class.lease_connection
    key = [ PROCESSING_LOCK_NAMESPACE, id.to_s ]

    connection.execute(self.class.sanitize_sql_array([ "SELECT pg_advisory_lock(?, hashtext(?))", *key ]))
    outermost = @processing_lock_session.nil?
    @processing_lock_session ||= backend_pid(connection)
    begin
      yield
    ensure
      release_processing_lock(connection, key)
      @processing_lock_session = nil if outermost
    end
  end

  # The session that took the processing lock ended while the block ran: a
  # broken connection that Rails opened again on the next query, on a new
  # session that holds no lock, so another processor may hold it now. What
  # deletes entries (WiseAccount::Transactions::Processor) waits for the
  # next sync then. false outside the lock.
  def processing_lock_lost?
    @processing_lock_session.present? && backend_pid(self.class.lease_connection) != @processing_lock_session
  end

  def account_subtype
    jar? ? "savings" : Depository::DEFAULT_SUBTYPE
  end

  def upsert_wise_snapshot!(balance_data, borderless_account_id: nil, recipient_id: nil)
    data = balance_data.with_indifferent_access
    payload = balance_data.is_a?(Hash) ? balance_data.dup : balance_data
    payload = payload.merge("borderless_account_id" => borderless_account_id) if borderless_account_id
    payload = payload.merge("recipient_id" => recipient_id) if recipient_id
    previous = raw_payload.is_a?(Hash) ? raw_payload : {}
    PRESERVED_KEYS.each do |key|
      payload = payload.merge(key => previous[key]) if previous.key?(key) && !payload.key?(key)
    end

    currency_code = data.dig(:amount, :currency).presence || data[:currency].presence || currency
    savings = data[:type] == "SAVINGS"
    # A STANDARD balance's amount leaves out what card holds keep back
    # (reservedAmount), while Sure books a card payment only once Wise
    # completes it, so the holds are counted back in. A jar's is totalWorth.
    balance_value = savings ? data.dig(:totalWorth, :value).to_d : data.dig(:amount, :value).to_d + data.dig(:reservedAmount, :value).to_d
    api_name = data[:name].presence
    default_name = savings ? "Wise JAR #{currency_code}" : "Wise #{currency_code}"

    update!(
      current_balance: balance_value,
      reserved_balance: data.dig(:reservedAmount, :value).to_d,
      currency: currency_code,
      name: name.presence || api_name || default_name,
      raw_payload: payload
    )
  end

  # statements_coverage: the coverage this sync's statement fetch extended
  # ({ "from", "through" } ISO-8601 strings), saved with the rows it brought.
  # prune_cap_bypass: what #prune_cap_bypass_ids lists from now on. Marks are
  # merged into the snapshot as stored now (#merge_raw_payload!), so an
  # opening anchor a link recorded meanwhile stays.
  def upsert_wise_transactions_snapshot!(transactions, statements_coverage: nil, prune_cap_bypass: nil)
    markers = { "statements_coverage" => statements_coverage, "prune_cap_bypass" => prune_cap_bypass }.compact
    return update!(raw_transactions_payload: transactions) if markers.empty?

    merge_raw_payload!(markers, raw_transactions_payload: transactions)
  end

  private

    # Merges the given keys into the snapshot as stored now, so a writer
    # holding an older copy of the balance loses nothing to it.
    def merge_raw_payload!(attributes, **others)
      self.class.transaction { update!(raw_payload: locked_raw_payload.merge(attributes), **others) }
    end

    # The stored snapshot, its row locked until the caller's transaction ends.
    def locked_raw_payload
      stored = self.class.lock.select(:id, :raw_payload).find(id).raw_payload
      stored.is_a?(Hash) ? stored : {}
    end

    # An unlock that does not run (the connection broke, the thread was
    # interrupted) would leave the lock with the connection; throwing the
    # connection away ends its session, which releases the lock. A session
    # that ended took the lock with it, and the new one has none to release.
    def release_processing_lock(connection, key)
      released = false
      if processing_lock_lost?
        Rails.logger.warn "WiseAccount #{id} - The processing lock ended with its database session while the balance was processed"
      else
        connection.execute(self.class.sanitize_sql_array([ "SELECT pg_advisory_unlock(?, hashtext(?))", *key ]))
      end
      released = true
    ensure
      connection.throw_away! unless released
    end

    def backend_pid(connection)
      connection.select_value("SELECT pg_backend_pid()")
    end

    def parse_utc(raw)
      ActiveSupport::TimeZone["UTC"].parse(raw.to_s) if raw.present?
    rescue ArgumentError
      nil
    end
end
