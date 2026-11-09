# frozen_string_literal: true

# Brings in the tricounts a connection follows: synchronises its sharing tokens
# to the connection's device, then reads each tricount whole (members and
# entries). Tricounts are small, so every sync reads every entry, and an entry
# deleted in Tricount drops out of the stored snapshot.
class TricountItem::Importer
  include SyncStats::Collector
  include CurrencyNormalizable

  attr_reader :tricount_item, :tricount_provider, :sync

  def initialize(tricount_item, tricount_provider:, sync: nil)
    @tricount_item = tricount_item
    @tricount_provider = tricount_provider
    @sync = sync
  end

  # Returns the ids of the tricounts read in full this time; only their
  # accounts take the snapshot as the balance now.
  def import
    tokens = tricount_item.sharing_token_list
    tricount_provider.synchronize!(tokens)
    count_request

    seen_ids = tokens.filter_map { |token| import_tricount(token) }
    prune_unfollowed_accounts(seen_ids) if stats.fetch("errors", []).empty?

    persist_stats!
    tricount_item.update!(status: :good) if tricount_item.requires_update?
    tricount_item.upsert_tricount_snapshot!(stats)
    seen_ids
  rescue Provider::Tricount::AuthenticationError
    tricount_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def count_request
      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)

      sync.update_columns(sync_stats: (sync.sync_stats || {}).merge(stats))
    end

    # Returns the tricount's id, or nil when it could not be read.
    def import_tricount(token)
      registry = tricount_provider.registry(token)
      count_request

      # A followed tricount that came back empty is a failed read, not an
      # unfollowed one: recording the error keeps its cached account from
      # being pruned and leaves the sync unhealthy.
      if registry.blank?
        stats["tricounts_missing"] = stats.fetch("tricounts_missing", 0) + 1
        register_error(StandardError.new(I18n.t("tricount_items.sync.errors.tricount_missing")))
        return nil
      end

      # A partial registry would replace what was imported with less: no
      # entry list zeroes the balance and removes every transaction, no
      # members drops the account's member, an entry without its shares
      # counts in full for its payer. Without its uuid it would be stored
      # under another key as a second tricount, and without a currency in
      # one it isn't in. Keep the snapshot and report it. (An empty entry
      # list is a tricount with no expenses.)
      if (problem = partial_registry_problem(registry))
        stats["tricounts_missing"] = stats.fetch("tricounts_missing", 0) + 1
        register_error(StandardError.new(I18n.t("tricount_items.sync.errors.#{problem}")))
        return nil
      end

      tricount_id = registry["uuid"].to_s
      tricount_account = tricount_item.tricount_accounts.find_or_initialize_by(tricount_account_id: tricount_id)
      tricount_account.upsert_from_tricount!(registry)

      stats["tricounts_imported"] = stats.fetch("tricounts_imported", 0) + 1
      stats["entries_found"] = stats.fetch("entries_found", 0) + tricount_account.raw_transactions_payload.size
      tricount_id
    rescue Provider::Tricount::AuthenticationError
      raise
    rescue => e
      Rails.logger.error "TricountItem::Importer - Failed to import a tricount for item #{tricount_item.id}: #{e.class}"
      register_error(e)
      nil
    end

    def partial_registry_problem(registry)
      # Tricounts are keyed by uuid alone, so one read with only its numeric
      # id doesn't become a second tricount.
      return "identifier_missing" if registry["uuid"].blank?
      return "currency_missing" if parse_currency(registry["currency"]).nil?

      entries = registry["all_registry_entry"]
      return "entries_missing" unless entries.is_a?(Array)

      memberships = registry["memberships"]
      return "members_missing" unless memberships.is_a?(Array) && memberships.any?

      # A member the ledger can't read would drop out, and with it the
      # account's chosen member.
      member_uuids = memberships.map { |wrapper| uuid_of(wrapper) }
      return "members_incomplete" if member_uuids.any?(&:nil?)

      # The ledger would count an entry listed twice twice, while its
      # transactions (keyed by the entry) are imported once.
      active_uuids = entries.filter_map do |raw|
        entry = TricountAccount::Ledger.unwrap(raw)
        entry["uuid"] if entry.is_a?(Hash) && (entry["status"].blank? || entry["status"] == TricountAccount::Ledger::ACTIVE)
      end
      return "entries_incomplete" if active_uuids.compact.uniq.size != active_uuids.compact.size

      incomplete = entries.any? do |raw|
        entry = TricountAccount::Ledger.unwrap(raw)
        next true unless entry.is_a?(Hash)

        active = entry["status"].blank? || entry["status"] == TricountAccount::Ledger::ACTIVE
        active && !complete_entry?(entry, member_uuids)
      end
      return "entries_incomplete" if incomplete

      # The ledger adds each expense's amount to the tricount's balance as it
      # stands, so one recorded in another currency would count at face value;
      # and a code that names no currency would fail its transaction's import
      # after the balance had been updated.
      currency = parse_currency(registry["currency"])
      foreign = entries.any? do |raw|
        entry = TricountAccount::Ledger.unwrap(raw)
        active = entry["status"].blank? || entry["status"] == TricountAccount::Ledger::ACTIVE
        code = entry.dig("amount", "currency")
        active && code.present? && parse_currency(code) != currency
      end
      "foreign_currency_entry" if foreign
    end

    # What the ledger needs of an active entry; one it can't read would drop
    # out of the snapshot and take its transactions with it, one without a
    # known payer would lose its paid leg, and a share it can't read would
    # drop out of the member's balance.
    def complete_entry?(entry, member_uuids)
      payer = uuid_of(entry["membership_owned"]) || entry["membership_uuid_owner"].presence
      amount = decimal(entry.dig("amount", "value"))

      # The type decides whether a share is spending or a settle-up.
      entry["uuid"].present? && entry["type_transaction"].present? && date_value?(entry["date"]) && amount &&
        member_uuids.include?(payer) && complete_allocations?(entry["allocations"], amount, member_uuids)
    end

    # Every share names a member of the tricount and an amount, and together
    # they make up the entry. Shares split by ratio are stored rounded to the
    # cent, so they may miss the total by up to a cent each; the ledger works
    # them out from their ratio, so one without a ratio would count only its
    # rounded amount.
    def complete_allocations?(allocations, amount, member_uuids)
      return false unless allocations.is_a?(Array) && allocations.any?

      shares = allocations.map do |allocation|
        return false unless allocation.is_a?(Hash)

        member = uuid_of(allocation["membership"]) || allocation["membership_uuid"].presence
        value = decimal(allocation.dig("amount", "value"))
        return false unless member_uuids.include?(member) && value
        return false if allocation["type"] == "RATIO" && !allocation["share_ratio"].to_i.positive?

        value
      end
      (shares.sum - amount).abs <= BigDecimal("0.01") * shares.size
    end

    def uuid_of(wrapper)
      membership = TricountAccount::Ledger.unwrap(wrapper)
      membership["uuid"].presence if membership.is_a?(Hash)
    end

    def decimal(value)
      BigDecimal(value.to_s, exception: false) if value.present?
    end

    # The ledger reads the date's first ten characters as an ISO date.
    def date_value?(value)
      value.present? && Date.iso8601(value.to_s[0, 10]).present?
    rescue ArgumentError
      false
    end

    # A tricount whose link was removed from the connection is dropped, unless
    # an account is linked to it: that account keeps the history it has.
    def prune_unfollowed_accounts(seen_ids)
      tricount_item.unlinked_tricount_accounts.where.not(tricount_account_id: seen_ids).destroy_all
    end

    def register_error(error)
      stats["errors"] ||= []
      stats["errors"] << { message: error.message, context: "tricount", timestamp: Time.current.iso8601 }
    end
end
