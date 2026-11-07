# Shows an eToro account split into copies (EtoroAccount#split_into_copies?):
# each copy-trading mirror is an account of its own, holding the mirror's
# positions and its uninvested cash, and the main account keeps the positions
# the user opened and the rest of the cash. Together they are eToro's total.
# Each account's cash is its part of the cash eToro's daily balances count,
# so the accounts' cash is eToro's on either side of the split, and what an
# account holds beside its cash and the holdings recorded of its positions,
# CFD equity among it, is its "eToro investments" holding, as in the totals
# mode.
#
# eToro reports no past figures of a mirror, so a copy's history is what Sure
# recorded of it (EtoroPortfolioSnapshot): it starts on the first day a sync
# saw the mirror, and each day is the day's last sync, carried over a day no
# sync ran. Before that day the main account holds the whole account, valued
# as the totals mode does: eToro's daily total and cash, with what is not cash
# one "eToro investments" holding. On that day the copy's positions move to
# the copy account as its holdings, and the rest of its value, its cash, as a
# transfer, and so do the money added to or taken out of a copy since the
# latest earlier day eToro sent those figures for (its depositSummary and
# withdrawalSummary) and, when the copy is closed, its last value back. From
# then on the main account's daily total is eToro's less its copies', and its
# holdings are those recorded of the positions the user opened. A copy not set
# up as an account stays in the main account: its positions in the
# investments holding and its cash as cash.
#
# Sure works out the days before today from the trades, so the holdings of
# every past day are reported as eToro's (see EtoroAccount::TotalsProcessor),
# and no trades of eToro's positions are kept.
class EtoroAccount::CopiesProcessor
  include EtoroAccount::DataHelpers

  HOLDING_PREFIX = "etoro_copies_".freeze
  TRANSFER_PREFIX = "etoro_copy_".freeze

  # Days of past holdings built and written at a time.
  HOLDING_DATE_BATCH = 30

  def self.holding_date_batch
    HOLDING_DATE_BATCH
  end

  # One part's snapshots, read for any day: the day's or the latest before
  # it. A closed snapshot is worth nothing.
  class Part
    attr_reader :mirror_id, :snapshots

    def initialize(mirror_id, snapshots)
      @mirror_id = mirror_id
      @snapshots = snapshots.sort_by(&:date)
      @dates = @snapshots.map(&:date)
    end

    def first_date
      @dates.first
    end

    def on(date)
      index = @dates.bsearch_index { |day| day > date } || @dates.size
      index.zero? ? nil : @snapshots[index - 1]
    end

    def total_on(date)
      snapshot = on(date)
      snapshot.nil? || snapshot.closed? ? BigDecimal("0") : snapshot.total
    end

    # What the part holds uninvested, which eToro's daily cash counts.
    def cash_on(date)
      snapshot = on(date)
      snapshot.nil? || snapshot.closed? ? BigDecimal("0") : snapshot.cash
    end

    # What the part's open positions are worth, CFDs included.
    def invested_on(date)
      total_on(date) - cash_on(date)
    end

    def holdings_on(date)
      snapshot = on(date)
      snapshot.nil? || snapshot.closed? ? {} : snapshot.holdings
    end

    # The first day the copy is worth nothing, if it was closed.
    def closed_on
      @snapshots.last&.closed? ? @dates.last : nil
    end

    # The money that moved between the main account and the copy, by day:
    # the copy's cash on the first day it is seen, or seen again, money
    # added to or taken out of it since the latest earlier day eToro sent
    # that figure for, and its last value when it is closed, which eToro
    # returns as cash. Each is [kind, date, amount], to the copy when the
    # kind is :opened or :deposit, with the amount to the 4 places a
    # transfer keeps; one that rounds to nothing is none.
    #
    # Only the copy's cash moves on its first day, as its positions arrive as
    # holdings: Sure takes a day's cash as the total less the holdings, so a
    # transfer of the whole value would leave the copy's cash below zero the
    # day before, by what the positions are worth.
    #
    # Money added or taken out is counted against the latest earlier day
    # eToro sent the figure for, so a day it sent none loses nothing.
    def movements
      previous = nil
      deposits = withdrawals = nil
      @snapshots.each_with_object([]) do |snapshot, moves|
        if snapshot.closed?
          moves << [ :closed, snapshot.date, previous.total ] if previous && !previous.closed?
        elsif previous.nil? || previous.closed?
          moves << [ :opened, snapshot.date, snapshot.cash ]
          deposits, withdrawals = snapshot.deposits, snapshot.withdrawals
        else
          if snapshot.deposits
            moves << [ :deposit, snapshot.date, snapshot.deposits - deposits ] if deposits
            deposits = snapshot.deposits
          end
          if snapshot.withdrawals
            moves << [ :withdrawal, snapshot.date, snapshot.withdrawals - withdrawals ] if withdrawals
            withdrawals = snapshot.withdrawals
          end
        end
        previous = snapshot
      end.map { |kind, date, amount| [ kind, date, amount.round(4) ] }.select { |_kind, _date, amount| amount.positive? }
    end
  end

  class << self
    # Takes off a main account no longer split what the split wrote: the past
    # holdings and the transfers to and from its copies, both sides.
    def clear(etoro_account)
      account = etoro_account.current_account
      return unless account

      account.holdings.where("external_id LIKE ?", "#{HOLDING_PREFIX}%").delete_all
      transfer_entries(account).each { |entry| destroy_transfer(entry) }
    end

    def transfer_entries(account)
      account.entries.where(source: "etoro", entryable_type: "Transaction").where("external_id LIKE ?", "#{TRANSFER_PREFIX}%")
    end

    def destroy_transfer(entry)
      transfer = entry.entryable&.transfer
      legs = [ entry, transfer&.inflow_transaction&.entry, transfer&.outflow_transaction&.entry ].compact.uniq
      Entry.transaction { legs.each(&:destroy!) }
    end
  end

  def initialize(etoro_account, securities: nil)
    @etoro_account = etoro_account
    @securities = securities
  end

  # Today's total: the mirror's for a copy; eToro's less the copies' shown
  # for the main account.
  def current_total
    return own_part.total_on(Date.current) if copy?

    (@etoro_account.current_balance || 0) - shown_copies.sum(BigDecimal("0")) { |_copy, part| part.total_on(Date.current) }
  end

  # The trades of eToro's positions, which the history is not worked out
  # from. A trade the user added stays.
  def remove_trades!
    account.entries.where(source: "etoro", entryable_type: "Trade").destroy_all
  end

  # What the account holds today beside its cash and the holdings the
  # holdings import valued at `holdings_value`, as its investments holding:
  # CFD equity, positions on instruments eToro has not described yet, and
  # for the main account the positions of the copies not set up as accounts.
  # Held at zero, as a holding cannot be worth less, so the cash takes the
  # rest. Returns it.
  def write_current_investments!(holdings_value)
    value = [ invested_on(Date.current) - holdings_value, BigDecimal("0") ].max.round(4)
    if value.positive?
      write_rows([ holding_row(investments_security, Date.current, 1, value) ])
    else
      account.holdings.where(security_id: investments_security.id, date: Date.current).delete_all
    end
    value
  end

  # [date, total] of each past day to reconcile the account to: from the
  # first snapshot to the day it was closed for a copy, and each day of
  # eToro's daily balances, less the copies' totals, for the main account.
  def daily_totals
    if copy?
      first = own_part.first_date
      return [] if first.nil?

      last = [ own_part.closed_on, Date.current.prev_day ].compact.min
      (first..last).map { |date| [ date, own_part.total_on(date) ] }
    else
      etoro_days.map do |date, (total, _cash)|
        [ date, total - shown_copies.sum(BigDecimal("0")) { |_copy, part| part.total_on(date) } ]
      end
    end
  end

  # The holdings of every day from the account's start to yesterday, as
  # reported, in place of those the days had: those recorded of the part's
  # positions, on the security a user moved a holding to, and the
  # investments holding. Each security has a zero on each day it was not
  # held, and today when it is no longer held, which keeps Sure from carrying
  # a holding back or forward over those days. The days' rows are replaced
  # only after the holdings import, which carries the user's changes to a
  # holding, such as a locked cost basis, from the day before's row to the
  # new day's, and in one transaction, so a sync that fails leaves them as
  # they were.
  def write_past_holdings!
    dates = (account.start_date..Date.current.prev_day).to_a
    held_today = account.holdings.where(date: Date.current, account_provider_id: provider_id).where.not(qty: 0).pluck(:security_id).to_set
    values = dates.index_with { |date| values_on(date) }
    security_ids = values.values.flat_map(&:keys).to_set | held_today
    prices = known_prices(values)

    Holding.transaction do
      account.holdings.where(date: ...Date.current).delete_all
      # Built a batch of days at a time, as the days times the securities
      # grow with the account's history.
      dates.each_slice(self.class.holding_date_batch) do |batch|
        write_rows(batch.flat_map do |date|
          security_ids.map do |security_id|
            qty, amount = values[date][security_id]
            qty&.positive? ? holding_row(security_id, date, qty, amount) : holding_row(security_id, date, 0, 0, price: prices[security_id])
          end
        end)
      end
      write_rows((security_ids - held_today).map { |security_id| holding_row(security_id, Date.current, 0, 0, price: prices[security_id]) })
    end
  end

  # Brings the transfers between the main account and each copy set up as
  # an account in line with the copies' movements. One that still matches
  # stays, with whatever the user set on it, and takes the movement's amount,
  # which changes with each sync on a copy's first day. Those of a disabled
  # copy stay as they are, as Sure no longer writes to its account, unless it
  # has none, as after a switch away from copies emptied it: the sync then
  # rebuilds its account (see EtoroAccount#processed_while_disabled?), and
  # they are made again with it. So do those of a copy whose account was
  # unlinked since this pass read the copies, as by a deletion of the
  # connection that a sync run on past its visible minutes no longer holds
  # up: its account is a manual one now, and the sync leaves it alone, as it
  # does the accounts it has not reached (see EtoroItem#process_accounts).
  def sync_transfers!
    return if copy?

    linked, unlinked = shown_copies.partition { |copy, _part| linked_now?(copy) }
    frozen_copies, synced = linked.partition { |copy, _part| copy.shown_account.disabled? && self.class.transfer_entries(copy.shown_account).exists? }
    frozen = (frozen_copies + unlinked).map { |copy, _part| "#{TRANSFER_PREFIX}#{copy.mirror_id}_" }

    wanted = synced.flat_map do |copy, part|
      part.movements.map do |kind, date, amount|
        [ "#{TRANSFER_PREFIX}#{copy.mirror_id}_#{kind}_#{date.iso8601}", { copy_account: copy.shown_account, kind: kind, date: date, amount: amount } ]
      end
    end.to_h

    self.class.transfer_entries(account).includes(:entryable).find_each do |entry|
      next if frozen.any? { |prefix| entry.external_id.start_with?(prefix) }

      movement = wanted[entry.external_id]
      next wanted.delete(entry.external_id) if movement && update_transfer(entry, movement)

      self.class.destroy_transfer(entry)
    end

    wanted.each { |external_id, movement| create_transfer(external_id, movement) }
  end

  private

    def copy?
      @etoro_account.copy?
    end

    def account
      @etoro_account.current_account
    end

    def provider_id
      @etoro_account.account_provider&.id
    end

    def currency
      @etoro_account.currency
    end

    def instruments_map
      @etoro_account.instruments_map
    end

    def owner
      @etoro_account.positions_owner
    end

    # The parts the account is worked out from, by mirror ID: a copy's own,
    # and for the main account the positions the user opened and the copies
    # set up as accounts. eToro's daily figures stand for the copies not set
    # up, so their snapshots are not read.
    def parts
      @parts ||= begin
        mirror_ids = copy? ? [ @etoro_account.mirror_id ] : [ EtoroPortfolioSnapshot::OWN_POSITIONS, *shown_copy_accounts.map(&:mirror_id) ]
        owner.portfolio_snapshots.where(mirror_id: mirror_ids).to_a.group_by(&:mirror_id).to_h { |mirror_id, snapshots| [ mirror_id, Part.new(mirror_id, snapshots) ] }
      end
    end

    def own_part
      parts[copy? ? @etoro_account.mirror_id : EtoroPortfolioSnapshot::OWN_POSITIONS] || Part.new(nil, [])
    end

    # The copies set up as accounts and shown, with their parts.
    def shown_copies
      @shown_copies ||= shown_copy_accounts.filter_map { |copy| [ copy, parts[copy.mirror_id] ] if parts.key?(copy.mirror_id) }
    end

    def shown_copy_accounts
      @shown_copy_accounts ||= owner.copy_accounts.includes(account_provider: :account).select(&:shown_account)
    end

    # Whether the copy's account is still the one linked to it, asked of the
    # database rather than of the link read when the pass began.
    def linked_now?(copy)
      AccountProvider.exists?(provider_type: "EtoroAccount", provider_id: copy.id, account_id: copy.shown_account.id)
    end

    # The first day the account's parts were recorded: the main account
    # holds the whole account, valued as totals, before it.
    def split_from
      @split_from ||= parts.values.filter_map(&:first_date).min || Date.current
    end

    # eToro's [total, cash] of each past day, as in the totals mode.
    def etoro_days
      @etoro_days ||= Array(owner.raw_balance_history_payload).each_with_object({}) do |snapshot, days|
        next if snapshot["currency"].present? && snapshot["currency"] != currency

        date = parse_date(snapshot["date"])
        total = parse_decimal(snapshot["total"])
        days[date] = [ total, parse_decimal(snapshot["cash"]) ] if date && total && date < Date.current
      end.sort.to_h
    end

    # [units, value] of a snapshot's holding of an instrument, less the part
    # it counted only because eToro had not described the instrument yet,
    # once eToro describes it as a CFD.
    def snapshot_held(instrument_id, held)
      units = parse_decimal(held["units"]) || BigDecimal("0")
      value = parse_decimal(held["value"]) || BigDecimal("0")
      type_id = instruments_map.dig(instrument_id.to_s, "type_id")
      return [ units, value ] if held["assumed_units"].nil? || type_id.nil? || REAL_ASSET_TYPE_IDS.include?(type_id.to_i)

      [ units - (parse_decimal(held["assumed_units"]) || 0), value - (parse_decimal(held["assumed_value"]) || 0) ]
    end

    # { security_id => [qty, amount] } of the account on a past day: the
    # holdings recorded of the part's positions, for the main account from
    # the split on, and what else the account holds beside its cash as the
    # investments holding, held at zero as on today (see
    # #write_current_investments!).
    def values_on(date)
      values = {}

      if copy? || date >= split_from
        own_part.holdings_on(date).each do |instrument_id, held|
          units, value = snapshot_held(instrument_id, held)
          next unless units.positive?

          security = trade_security_for(instrument_id)
          next unless security

          qty, amount = values[security.id] || [ BigDecimal("0"), BigDecimal("0") ]
          values[security.id] = [ qty + units, amount + value ]
        end
      end

      invested = invested_on(date) - values.values.sum(BigDecimal("0")) { |_qty, amount| amount }
      values[investments_security.id] = [ BigDecimal("1"), invested ] if invested.positive?

      values
    end

    # What the account holds beside its cash on a day: a copy's positions,
    # and for the main account eToro's total less its cash, today's or a
    # past day's as in the totals mode, less the positions of the copies set
    # up as accounts. Before the split no copy has any, so the main account
    # holds eToro's figures as they are.
    def invested_on(date)
      return own_part.invested_on(date) if copy?

      etoro = if date == Date.current
        (@etoro_account.current_balance || 0) - (@etoro_account.cash_balance || 0)
      else
        totals_investments_on(date) || 0
      end
      etoro - shown_copies.sum(BigDecimal("0")) { |_copy, part| part.invested_on(date) }
    end

    # The totals mode's investments value of a past day: eToro's total less
    # its cash, carried from the day before over a day eToro sent no figures
    # for.
    def totals_investments_on(date)
      @totals_investments ||= begin
        last = nil
        etoro_days.transform_values do |total, cash|
          last = cash ? [ total - cash, BigDecimal("0") ].max : last
        end
      end

      day = @totals_investments.keys.select { |known| known <= date }.max
      day && @totals_investments[day]
    end

    def known_prices(values)
      values.values.each_with_object({}) do |day, prices|
        day.each { |security_id, (qty, amount)| prices[security_id] ||= (amount / qty).round(4) if qty.positive? }
      end.tap do |prices|
        account.holdings.where(date: Date.current).where.not(qty: 0).pluck(:security_id, :price).each { |id, price| prices[id] ||= price }
      end
    end

    def investments_security
      @investments_security ||= EtoroAccount::TotalsProcessor.security_for(account)
    end

    # A row of a security a user moved a holding to keeps the move, as the
    # holdings import's rows do, so a later sync still finds it once the
    # holding is no longer held (see DataHelpers#remapped_securities).
    #
    # Holding::CurrentForInvestmentAccounts counts every provider holding
    # written on the account's latest import day as current, whatever day it
    # is for. So a past day's row is stamped with the end of that day, as if
    # written then, and only today's with the time of this sync.
    def holding_row(security, date, qty, amount, price: nil)
      security_id = security.respond_to?(:id) ? security.id : security
      written_at = date < Date.current ? date.in_time_zone("UTC").end_of_day : Time.current
      {
        account_id: account.id,
        security_id: security_id,
        date: date,
        currency: currency,
        qty: qty,
        price: price || (qty.positive? ? (amount / qty).round(4) : 0),
        amount: amount.round(4),
        account_provider_id: provider_id,
        provider_security_id: remapped_from[security_id],
        security_locked: remapped_from.key?(security_id),
        external_id: "#{HOLDING_PREFIX}#{@etoro_account.etoro_account_id}_#{security_id}_#{date.iso8601}",
        created_at: written_at,
        updated_at: written_at
      }
    end

    # The security eToro reported each moved holding as, by the security the
    # user moved it to.
    def remapped_from
      @remapped_from ||= remapped_securities.to_h { |provider_security_id, security| [ security.id, provider_security_id ] }
    end

    def write_rows(rows)
      rows.each_slice(500) { |batch| Holding.upsert_all(batch, unique_by: %i[account_id security_id date currency], record_timestamps: false) }
    end

    # Gives a transfer between the same accounts on the movement's day the
    # movement's amount. Returns whether it is that transfer.
    def update_transfer(entry, movement)
      transfer = entry.entryable.transfer
      counterpart = transfer&.then { |found| [ found.inflow_transaction, found.outflow_transaction ] }&.map(&:entry)&.find { |leg| leg != entry }
      return false unless entry.date == movement[:date] && counterpart&.account_id == movement[:copy_account].id

      amount = %i[opened deposit].include?(movement[:kind]) ? movement[:amount] : -movement[:amount]
      return true if entry.amount == amount

      Entry.transaction do
        entry.update!(amount: amount)
        counterpart.update!(amount: -amount)
        transfer.reload.update!(amount: movement[:amount])
      end
      true
    end

    def create_transfer(external_id, movement)
      copy_account = movement[:copy_account]
      from, to = %i[opened deposit].include?(movement[:kind]) ? [ account, copy_account ] : [ copy_account, account ]

      Entry.transaction do
        self.class.transfer_entries(copy_account).where(external_id: external_id).find_each { |stale| self.class.destroy_transfer(stale) }

        outflow = transfer_leg(from, external_id, movement, movement[:amount], I18n.t("etoro_items.copies.transfer_to", account: to.name))
        inflow = transfer_leg(to, external_id, movement, -movement[:amount], I18n.t("etoro_items.copies.transfer_from", account: from.name))
        Transfer.create!(inflow_transaction: inflow.entryable, outflow_transaction: outflow.entryable, status: "confirmed", amount: movement[:amount])
      end
    end

    def transfer_leg(account, external_id, movement, amount, name)
      account.entries.create!(
        date: movement[:date], name: name, amount: amount, currency: account.currency,
        source: "etoro", external_id: external_id,
        entryable: Transaction.new(kind: "funds_movement")
      )
    end
end
