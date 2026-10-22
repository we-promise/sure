# frozen_string_literal: true

# Links the two legs of each move between one Wise profile's own balances -- a
# currency conversion or a Jar move -- as a confirmed Transfer.
#
# WiseActivity::Processor books such a move (INTERBALANCE, and AUTO_CONVERSION
# through the same two-leg path) as wise_interbalance_<resource id>_outflow on
# the balance the money left and wise_interbalance_<resource id>_inflow on the
# balance it reached, both as standard transactions. Wise's activity feed is
# the authority on that pair, so the link is confirmed straight away and the
# legs get the kinds Transfer#confirm! gives a match the user confirms;
# without them every conversion counts as income on one balance and spending
# on the other. A transfer from one balance into another's own account
# details ("send to myself") is linked the same way from the two statement
# rows that carry it (#link_sends_to_own_balances).
class WiseItem::InterbalanceLinker
  LEG_EXTERNAL_ID = /\Awise_interbalance_(?<resource_id>.+)_(?<side>inflow|outflow)\z/
  # The entry of a transfer's statement row, under the reference Wise gives
  # the transfer in every balance's statement (WiseStatement::Processor).
  TRANSFER_STATEMENT_EXTERNAL_ID = /\Awise_statement_(?<reference>TRANSFER-\d+)(?:_(?<suffix>.+))?\z/
  # Activity types whose payload rows describe a two-leg move (the ones
  # WiseActivity::Processor books as these legs), used to find the currency
  # the money left in.
  TWO_LEG_ACTIVITY_TYPES = WiseActivity::Processor::TWO_LEG_TYPES
  # A pair that cannot be linked fails again on every sync, so problems go into
  # one debug log entry per run, with this many listed.
  MAX_LOGGED_PROBLEMS = 20

  attr_reader :wise_item, :stats

  # Whether a transfer is a link of the kind this linker makes: the inflow
  # and the outflow leg of one move (the same resource id) on the given
  # accounts, with nothing a person added to it (notes, or a fee, which goes
  # with the transfer when a leg is deleted).
  def self.system_link?(transfer, account_ids)
    sides = { "inflow" => transfer.inflow_transaction&.entry, "outflow" => transfer.outflow_transaction&.entry }
    resource_ids = sides.map do |side, entry|
      match = LEG_EXTERNAL_ID.match(entry.external_id.to_s) if entry&.source == "wise" && account_ids.include?(entry.account_id)
      match[:resource_id] if match && match[:side] == side
    end

    resource_ids.first.present? && resource_ids.uniq.one? && transfer.notes.blank? && !transfer.fee_transactions.exists?
  end

  # Whether the linker links a transfer's legs again on the next sync after
  # a person removes the transfer: one of the links it makes, between two
  # balances of one connection. Removing such a link rejects it instead
  # (TransfersController#destroy), so it stays removed.
  def self.relinks?(transfer)
    entries = [ transfer.inflow_transaction&.entry, transfer.outflow_transaction&.entry ]
    return false unless entries.all? { |entry| entry&.source == "wise" }

    item_ids = WiseAccount.joins(:account_provider).where(account_providers: { account_id: entries.map(&:account_id) }).distinct.pluck(:wise_item_id)
    return false unless item_ids.one?

    system_link?(transfer, WiseItem.find(item_ids.first).accounts.pluck(:id).to_set) || send_link?(transfer)
  end

  # A link of the two statement rows of a "send to myself": one reference,
  # money out of one balance and into another, nothing a person added.
  def self.send_link?(transfer)
    inflow, outflow = transfer.inflow_transaction&.entry, transfer.outflow_transaction&.entry
    references = [ inflow, outflow ].map { |entry| transfer_reference(entry&.external_id) }
    references.first.present? && references.uniq.one? && inflow.account_id != outflow.account_id &&
      transfer.notes.blank? && !transfer.fee_transactions.exists?
  end

  # The TRANSFER-<id> reference of a transfer's statement row entry; nil for
  # its fee's and any other entry.
  def self.transfer_reference(external_id)
    match = TRANSFER_STATEMENT_EXTERNAL_ID.match(external_id.to_s)
    match[:reference] if match && !match[:suffix].to_s.end_with?("fee")
  end

  def initialize(wise_item)
    @wise_item = wise_item
    @stats = Hash.new(0)
    @problems = []
  end

  def link!
    return stats if wise_accounts_by_account_id.empty?

    legs_by_resource_id.each do |resource_id, legs|
      legs[:inflow].each { |inflow| link_leg(resource_id, inflow, legs[:outflow]) }
    end
    link_sends_to_own_balances
    discard_suggestions_within_item!
    log_outcome
    stats
  end

  private

    def wise_accounts_by_account_id
      @wise_accounts_by_account_id ||= wise_item.wise_accounts
                                                .joins(:account_provider)
                                                .includes(:account_provider)
                                                .index_by { |wise_account| wise_account.account_provider.account_id }
    end

    def item_account_ids
      wise_accounts_by_account_id.keys
    end

    # { resource_id => { inflow: [entries], outflow: [entries] } }
    def legs_by_resource_id
      Entry.where(source: "wise", account_id: item_account_ids, entryable_type: "Transaction")
           .where("external_id LIKE ?", "#{Entry.sanitize_sql_like("wise_interbalance_")}%")
           .includes(:entryable)
           .order(:date, :external_id)
           .each_with_object({}) do |entry, legs|
        match = LEG_EXTERNAL_ID.match(entry.external_id)
        next unless match

        sides = legs[match[:resource_id]] ||= { inflow: [], outflow: [] }
        sides[match[:side].to_sym] << entry
      end
    end

    def link_leg(resource_id, inflow, outflows)
      outflow = outflow_for(resource_id, inflow, outflows)
      link_entries(inflow, outflow, resource_id: resource_id) if outflow
    end

    def link_entries(inflow, outflow, **details)
      # A savepoint even when the caller holds a transaction (a lock, say), so
      # a refused link rolls back only its own changes, the replaced
      # suggestions included.
      outcome = Transfer.transaction(requires_new: true) { link_pair(inflow.entryable, outflow.entryable) }
      stats[outcome] += 1
      add_problem(:kept_link_to_copy, inflow, **details) if outcome == :kept_link_to_copy
    rescue => e
      stats[:failed] += 1
      errors = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages : [ e.message ]
      add_problem(:link_failed, inflow, **details, error_class: e.class.name, errors: errors)
    end

    # A transfer from one of the profile's balances into another's own
    # account details is in both balances' statements under one
    # TRANSFER-<id> reference: a debit where the money left and a credit
    # where it arrived. Linked like a conversion when the reference has one
    # of each on two balances (a refund credit is on the paying balance);
    # the automatic matcher pairs no two balances of one connection.
    def link_sends_to_own_balances
      sends = Entry.where(source: "wise", account_id: item_account_ids, entryable_type: "Transaction")
                   .where("external_id LIKE ?", "#{Entry.sanitize_sql_like("wise_statement_TRANSFER-")}%")
                   .includes(:entryable)
                   .group_by { |entry| self.class.transfer_reference(entry.external_id) }
      sends.except(nil).each do |reference, entries|
        outflows, inflows = entries.partition { |entry| entry.amount.positive? }
        next unless outflows.one? && inflows.one? && outflows.first.account_id != inflows.first.account_id

        link_entries(inflows.first, outflows.first, reference: reference)
      end
    end

    # The leg on another balance of this item with the same resource id. An
    # install synced before conversions were routed by currency can also hold
    # legs that routing booked on every STANDARD balance (the inflow's own one
    # included), so only the leg on the balance in the move's source currency
    # qualifies; without the move's stored row, only a leg that is not such
    # a copy (#pre_routing_copy?). Anything still ambiguous stays unlinked
    # and is logged rather than guessed.
    def outflow_for(resource_id, inflow, outflows)
      candidates = outflows.reject { |leg| leg.account_id == inflow.account_id }
      return if candidates.empty?

      source_currency = source_currency_for(resource_id)
      matches =
        if source_currency
          candidates.select { |leg| balance_currency(leg) == source_currency }
        else
          candidates.reject { |leg| pre_routing_copy?(leg) }
        end
      return matches.first if matches.one?

      stats[:ambiguous] += 1
      add_problem(:no_single_outflow_leg, inflow, resource_id: resource_id, candidate_count: candidates.size,
                  source_currency_match_count: source_currency ? matches.size : nil)
      nil
    end

    def link_pair(inflow_txn, outflow_txn)
      pair, others = transfers_touching(inflow_txn, outflow_txn).partition do |transfer|
        transfer.inflow_transaction_id == inflow_txn.id && transfer.outflow_transaction_id == outflow_txn.id
      end
      pair = pair.first

      return repair_kinds(pair, inflow_txn, outflow_txn) if pair&.confirmed?

      # A leg the user confirmed against another transaction is their call,
      # but not a link this linker made to a copy of the other leg that
      # routing by currency has since replaced (#linked_to_copy?), or one it
      # made the wrong way round (#reversed_link?).
      leg_ids = [ inflow_txn.id, outflow_txn.id ]
      stale, confirmed = others.select(&:confirmed?).partition do |transfer|
        reversed_link?(transfer, inflow_txn, outflow_txn) ||
          (linked_to_copy?(transfer, leg_ids) && self.class.system_link?(transfer, item_account_ids))
      end
      if confirmed.any?
        return confirmed.any? { |transfer| linked_to_copy?(transfer, leg_ids) } ? :kept_link_to_copy : :kept_confirmed_elsewhere
      end
      return :rejected if RejectedTransfer.exists?(inflow_transaction_id: inflow_txn.id, outflow_transaction_id: outflow_txn.id)

      # Pending transfers are the automatic matcher's guesses; Uniqueness
      # allows one transfer per leg, so they make way for the feed's pair. An
      # exact guess is confirmed in place.
      others.each(&:destroy!)
      transfer = pair || Transfer.new(inflow_transaction: inflow_txn, outflow_transaction: outflow_txn, status: "confirmed")
      transfer.save! if transfer.new_record?
      transfer.confirm!

      stats[:replaced_stale_links] += stale.size
      stats[:replaced_suggestions] += others.size - stale.size
      :linked
    end

    # A link of these two legs with inflow and outflow swapped, nothing a
    # person added: what the linker made of a jar withdrawal an older build
    # booked as a deposit, before the legs' sides followed the money
    # (WiseActivity::Processor#superseded_external_ids renames them).
    def reversed_link?(transfer, inflow_txn, outflow_txn)
      transfer.inflow_transaction_id == outflow_txn.id && transfer.outflow_transaction_id == inflow_txn.id &&
        transfer.notes.blank? && !transfer.fee_transactions.exists?
    end

    # Whether a transfer pairs one of the given legs with a copy of the other
    # leg (#pre_routing_copy?): the linker before routing by currency
    # confirmed a jar move's leg against whichever copy it found first.
    def linked_to_copy?(transfer, leg_ids)
      counterpart = [ transfer.inflow_transaction, transfer.outflow_transaction ].compact.find { |txn| leg_ids.exclude?(txn.id) }
      counterpart&.entry.present? && pre_routing_copy?(counterpart.entry)
    end

    # A leg booked in another currency than its balance's: routing before
    # conversions and jar moves went by currency booked a copy of each on
    # every STANDARD balance, in the move's currency, while
    # WiseActivity::Processor books every leg in its own balance's currency.
    def pre_routing_copy?(entry)
      currency = balance_currency(entry)
      entry.source == "wise" && currency.present? && entry.currency != currency
    end

    def transfers_touching(*transactions)
      ids = transactions.map(&:id)
      Transfer.where(inflow_transaction_id: ids).or(Transfer.where(outflow_transaction_id: ids)).to_a
    end

    # Links made before the legs got transfer kinds left both standard.
    def repair_kinds(transfer, inflow_txn, outflow_txn)
      return :already_linked unless inflow_txn.standard? || outflow_txn.standard?

      transfer.confirm!
      :repaired
    end

    # The automatic matcher no longer pairs two balances of one item (see
    # Family::AutoTransferMatchable#auto_match_transfers!), but suggestions it
    # made before -- a GBP top-up "matching" a USD payout -- would stay
    # pending forever.
    def discard_suggestions_within_item!
      item_transaction_ids = Entry.where(account_id: item_account_ids, entryable_type: "Transaction").select(:entryable_id)

      Transfer.pending
              .where(inflow_transaction_id: item_transaction_ids, outflow_transaction_id: item_transaction_ids)
              .find_each do |transfer|
        transfer.destroy!
        stats[:discarded_suggestions] += 1
      end
    rescue => e
      add_problem(:discard_failed, nil, error_class: e.class.name, errors: [ e.message ])
    end

    # The currency the money left in, from the activity row the legs were
    # booked from: secondaryAmount for a conversion, primaryAmount for a move
    # within one currency. Nil when no stored row describes the move.
    def source_currency_for(resource_id)
      row = two_leg_rows[resource_id]
      return unless row

      money_currency(row["secondaryAmount"]) || money_currency(row["primaryAmount"])
    end

    def two_leg_rows
      @two_leg_rows ||= wise_accounts_by_account_id.each_value.with_object({}) do |wise_account, rows|
        Array(wise_account.raw_transactions_payload).each do |row|
          next unless row.is_a?(Hash) && TWO_LEG_ACTIVITY_TYPES.include?(row["type"])

          resource_id = row.dig("resource", "id").to_s
          rows[resource_id] ||= row if resource_id.present?
        end
      end
    end

    def money_currency(amount)
      WiseActivity::Processor.parse_money(amount).last.presence
    end

    def balance_currency(leg)
      wise_accounts_by_account_id[leg.account_id]&.currency
    end

    def add_problem(reason, inflow, **details)
      wise_account = inflow && wise_accounts_by_account_id[inflow.account_id]
      @problems << { reason: reason, wise_account_id: wise_account&.id, **details }.compact
    end

    def log_outcome
      counts = stats.slice(:linked, :repaired, :replaced_suggestions, :replaced_stale_links, :discarded_suggestions, :already_linked,
                           :kept_confirmed_elsewhere, :kept_link_to_copy, :rejected, :ambiguous, :failed)
      message = "WiseItem::InterbalanceLinker - #{counts.map { |key, count| "#{key}: #{count}" }.join(", ").presence || "nothing to link"}"
      Rails.logger.public_send(@problems.any? ? :warn : :info, message)

      # Problems, kinds changed on existing entries, or links and suggestions
      # that went away are worth a trace for support. Routine new links are not.
      return if @problems.empty? && stats.values_at(:repaired, :replaced_suggestions, :replaced_stale_links, :discarded_suggestions).sum.zero?

      DebugLogEntry.capture(
        category: @problems.any? ? "provider_sync_error" : "provider_sync",
        level: @problems.any? ? "warn" : "info",
        message: message,
        source: self.class.name,
        provider_key: "wise",
        family: wise_item.family,
        metadata: { wise_item_id: wise_item.id, **counts, problems: @problems.first(MAX_LOGGED_PROBLEMS).presence }.compact
      )
    end
end
