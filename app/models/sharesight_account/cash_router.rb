# Keeps the investment account to just its shares when the money lives
# somewhere else (see SharesightAccount::CashSettings).
#
# Every record that moved cash in the investment account gets an opposite
# "Transfer" entry there, so the cash nets to zero all the way back through the
# history. If the money went to an account in Sure, we link that entry to the
# other side as a confirmed transfer:
# - If the account comes from a bank feed, the transaction's already there, so
#   we look for it by amount (to the cent) and direction within the settlement
#   window, including a day's trades settled as one amount. Anything not found
#   is retried each sync and reported once it's overdue.
# - If it's a manual account, we book the other side ourselves.
class SharesightAccount::CashRouter
  include SharesightAccount::TransferLinking

  OFFSET_PREFIX = "sharesight_offset_".freeze
  COUNTERPART_PREFIX = "sharesight_counterpart_".freeze

  # One offset entry, for one record or a day's trades settled together.
  Unit = Struct.new(:key, :kind, :date, :currency, :amount, :target, :leftover, :description, :bank_entry, keyword_init: true)

  attr_reader :notices

  def initialize(sharesight_account, movements)
    @sharesight_account = sharesight_account
    @movements = movements
    @notices = []
  end

  def route
    return unless account

    units = match_bank_transactions(build_units)
    counterpart_ids = units.filter_map { |unit| settle(unit) }

    remove_stale_offsets(units)
    remove_stale_counterparts(counterpart_ids)
    report_unsettled(units)
  end

  private

    def account
      @account ||= @sharesight_account.current_account
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def build_units
      @movements.filter_map do |movement|
        destination = if movement.kind == :dividend
          @sharesight_account.dividend_destination_on(movement.date)
        else
          @sharesight_account.trade_destination_on(movement.date)
        end
        next if destination.nil? || destination == :skip || movement.amount.zero?

        # Opening balances never go near a bank, and a settlement account can
        # only settle in its own currency.
        target = destination if destination.is_a?(Account) && movement.matchable && destination.currency == movement.currency
        # A reinvested dividend's leftover is only linked if a bank feed shows
        # it arriving. We don't book it into a manual account on a guess.
        target = nil if movement.leftover && !bank_fed?(target)

        Unit.new(
          key: movement.key,
          kind: movement.kind,
          date: movement.date,
          currency: movement.currency,
          amount: movement.amount,
          target: target,
          leftover: movement.leftover,
          description: movement.description
        )
      end
    end

    def bank_fed?(target)
      target&.linked?
    end

    # Keep links from earlier syncs first, so a later look-alike can't steal them.
    def match_bank_transactions(units)
      claimed = Set.new
      matchable = units.select { |unit| bank_fed?(unit.target) }

      matchable.each do |unit|
        linked = linked_bank_entry(unit.key, unit.target)
        next unless linked

        if linked.amount == unit.amount && claimed.add?(linked.id)
          unit.bank_entry = linked
        else
          offset_entry(unit.key).entryable.transfer&.destroy!
        end
      end

      matchable.each do |unit|
        next if unit.bank_entry

        unit.bank_entry = find_bank_entry(unit, claimed)
        claimed << unit.bank_entry.id if unit.bank_entry
      end

      combine_days(units, claimed)
    end

    # Some brokers settle a day's trades as one net amount.
    def combine_days(units, claimed)
      groups = units.select { |unit| unit.kind == :trade && bank_fed?(unit.target) && unit.bank_entry.nil? }
        .group_by { |unit| [ unit.target, unit.date, unit.currency ] }
        .select { |_, group| group.size > 1 }

      groups.each do |(target, date, currency), group|
        day = Unit.new(
          key: "day_#{date.iso8601}_#{currency}",
          kind: :trade,
          date: date,
          currency: currency,
          amount: group.sum(&:amount),
          target: target,
          description: "Sharesight trades on #{date.iso8601}"
        )
        next if day.amount.zero?

        linked = linked_bank_entry(day.key, target)
        day.bank_entry = linked if linked && linked.amount == day.amount && claimed.add?(linked.id)
        day.bank_entry ||= find_bank_entry(day, claimed)
        next unless day.bank_entry

        claimed << day.bank_entry.id
        units = (units - group) + [ day ]
      end

      units
    end

    def find_bank_entry(unit, claimed)
      window = @sharesight_account.settlement_window_days
      rejected = rejected_partner_ids(unit.key)

      unit.target.entries
        .where(entryable_type: "Transaction", excluded: false, currency: unit.currency, amount: unit.amount)
        .where(date: (unit.date - 1)..(unit.date + window))
        .where.not(id: claimed.to_a)
        .includes(:entryable)
        .reject { |entry| entry.entryable.transfer.present? || rejected.include?(entry.entryable_id) }
        .min_by { |entry| [ (entry.date - unit.date).abs, entry.date ] }
    end

    def offset_entry(key)
      account.entries.find_by(source: "sharesight", external_id: "#{OFFSET_PREFIX}#{key}")
    end

    # The other side of an offset entry's transfer, if it's in the target account.
    def linked_bank_entry(key, target)
      transfer = offset_entry(key)&.entryable&.transfer
      return unless transfer

      [ transfer.inflow_transaction, transfer.outflow_transaction ].map(&:entry).find { |entry| entry.account_id == target.id }
    end

    def rejected_partner_ids(key)
      leg_transaction_id = offset_entry(key)&.entryable_id
      return Set.new unless leg_transaction_id

      RejectedTransfer.where(inflow_transaction_id: leg_transaction_id).pluck(:outflow_transaction_id).to_set |
        RejectedTransfer.where(outflow_transaction_id: leg_transaction_id).pluck(:inflow_transaction_id)
    end

    # Books the offset entry and links it. Returns the counterpart's external id
    # if we booked one in a manual account.
    def settle(unit)
      leg = import_adapter.import_transaction(
        external_id: "#{OFFSET_PREFIX}#{unit.key}",
        amount: -unit.amount,
        currency: unit.currency,
        date: unit.date,
        name: offset_name(unit),
        source: "sharesight",
        investment_activity_label: "Transfer",
        allow_heuristic_matching: false,
        extra: { sharesight: { settles: unit.key } }
      )

      if unit.bank_entry
        link_transfer!(leg, unit.bank_entry)
        nil
      elsif unit.target && !bank_fed?(unit.target)
        counterpart = book_counterpart(unit)
        link_transfer!(leg, counterpart)
        counterpart.external_id
      end
    rescue => e
      DebugLogEntry.capture(
        category: "sync",
        level: "error",
        message: "SharesightAccount::CashRouter - Failed to settle #{unit.key}: #{e.message}",
        source: "sharesight",
        family: @sharesight_account.sharesight_item.family,
        provider_key: "sharesight"
      )
      nil
    end

    def offset_name(unit)
      return "Settled outside Sure" unless unit.target && (unit.bank_entry || !unit.leftover)

      unit.amount.positive? ? "Transfer from #{unit.target.name}" : "Transfer to #{unit.target.name}"
    end

    def book_counterpart(unit)
      Account::ProviderImportAdapter.new(unit.target).import_transaction(
        external_id: counterpart_external_id(unit),
        amount: unit.amount,
        currency: unit.currency,
        date: unit.date,
        name: unit.description,
        source: "sharesight",
        allow_heuristic_matching: false,
        extra: { sharesight: { settles: unit.key } }
      )
    end

    def counterpart_external_id(unit)
      "#{COUNTERPART_PREFIX}#{@sharesight_account.id}_#{unit.key}"
    end

    def remove_stale_offsets(units)
      current = units.map { |unit| "#{OFFSET_PREFIX}#{unit.key}" }

      account.entries
        .where(source: "sharesight")
        .where("entries.external_id LIKE ?", "#{Entry.sanitize_sql_like(OFFSET_PREFIX)}%")
        .where.not(external_id: current)
        .destroy_all
    end

    def remove_stale_counterparts(current)
      Entry.joins(:account)
        .where(accounts: { family_id: account.family_id }, source: "sharesight")
        .where("entries.external_id LIKE ?", "#{Entry.sanitize_sql_like("#{COUNTERPART_PREFIX}#{@sharesight_account.id}_")}%")
        .where.not(external_id: current)
        .destroy_all
    end

    def report_unsettled(units)
      window = @sharesight_account.settlement_window_days

      units.each do |unit|
        next unless bank_fed?(unit.target) && unit.bank_entry.nil? && !unit.leftover && unit.date + window < Date.current

        @notices << {
          message: I18n.t(
            unit.amount.positive? ? "sharesight_accounts.notices.unsettled_debit" : "sharesight_accounts.notices.unsettled_credit",
            amount: Money.new(unit.amount.abs, unit.currency).format,
            account: unit.target.name,
            description: unit.description,
            date: I18n.l(unit.date)
          ),
          severity: "warning"
        }
      end
    end
end
