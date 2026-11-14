class EtoroAccount::Processor
  attr_reader :etoro_account

  def initialize(etoro_account)
    @etoro_account = etoro_account
  end

  # Returns the number of holdings imported and of records (holdings, trades,
  # daily balances) that failed to import.
  def process
    return unless account.present?

    # Setup and linking run this inside a request, in the family's zone,
    # while sync jobs run it in UTC. eToro's daily balances are UTC days, so
    # the anchor, the holdings snapshot and the trades are dated in UTC
    # either way.
    result = Time.use_zone("UTC") { import_records }
    account.broadcast_sync_complete
    result
  end

  private

    def import_records
      return import_copy if etoro_account.copy?
      return import_split if etoro_account.shown_as_copies?

      EtoroAccount::CopiesProcessor.clear(etoro_account)
      update_account_balance!
      return import_totals if etoro_account.shown_as_totals?

      EtoroAccount::TotalsProcessor.clear(account)
      securities = {}
      holdings = EtoroAccount::HoldingsProcessor.new(etoro_account, securities: securities)
      holdings_value = holdings.process
      # Cash is whatever the holdings don't account for, so CFD equity and
      # money parked in copy-trading mirrors count as cash.
      account.update!(cash_balance: total_balance - holdings_value)

      activities = EtoroAccount::ActivitiesProcessor.new(etoro_account, securities: securities)
      activities.process
      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account)
      balance_history.process
      account.ensure_opening_anchor_precedes_entries

      {
        holdings: holdings.imported_count,
        failed_records: holdings.failed_count + activities.failed_count + balance_history.failed_count
      }
    end

    def import_totals
      totals = EtoroAccount::TotalsProcessor.new(etoro_account)
      account.update!(cash_balance: total_balance - totals.process)

      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account)
      balance_history.process
      totals.fit_opening_anchor!

      { holdings: 1, failed_records: balance_history.failed_count }
    end

    # The main account of an account split into copies: the positions the
    # user opened, and in its investments holding what else it holds beside
    # its cash, the positions of copies not set up as accounts among it.
    def import_split
      securities = {}
      copies = EtoroAccount::CopiesProcessor.new(etoro_account, securities: securities)
      total = copies.current_total
      update_account_balance!(total)
      copies.remove_trades!

      holdings = EtoroAccount::HoldingsProcessor.new(etoro_account, securities: securities)
      holdings_value = holdings.process
      account.update!(cash_balance: total - holdings_value - copies.write_current_investments!(holdings_value))

      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account, totals: copies.daily_totals)
      balance_history.process
      copies.sync_transfers!
      EtoroAccount::TotalsProcessor.fit_opening_anchor!(account)
      copies.write_past_holdings!

      { holdings: holdings.imported_count, failed_records: holdings.failed_count + balance_history.failed_count }
    end

    # A copy's account, which counts nothing while its main account is not
    # split: the main account shows the copy's positions then. It keeps its
    # link, for a return to copies, which rebuilds it from the snapshots.
    def import_copy
      securities = {}
      copies = EtoroAccount::CopiesProcessor.new(etoro_account, securities: securities)

      unless etoro_account.split_into_copies?
        # Setting today's balance turns the anchor of an earlier day, with
        # the copy's value that day, into a reconciliation, so it is set
        # before what the syncs wrote goes. An emptied account's anchor of
        # zero turns into one each day too; taking it off empties nothing.
        update_account_balance!(BigDecimal("0"), cash: BigDecimal("0"))
        emptied = synced_entries.destroy_all.any? { |entry| entry.amount.nonzero? }
        emptied = account.holdings.delete_all.positive? || emptied
        EtoroAccount::TotalsProcessor.fit_opening_anchor!(account)
        sync_disabled_account if emptied
        return { holdings: 0, failed_records: 0 }
      end

      total = copies.current_total
      update_account_balance!(total)
      copies.remove_trades!

      holdings = EtoroAccount::HoldingsProcessor.new(etoro_account, securities: securities)
      holdings_value = holdings.process
      account.update!(cash_balance: total - holdings_value - copies.write_current_investments!(holdings_value))

      balance_history = EtoroAccount::BalanceHistoryProcessor.new(etoro_account, totals: copies.daily_totals)
      balance_history.process
      EtoroAccount::TotalsProcessor.fit_opening_anchor!(account)
      copies.write_past_holdings!
      sync_disabled_account

      { holdings: holdings.imported_count, failed_records: holdings.failed_count + balance_history.failed_count }
    end

    # The connection's sync leaves a disabled account out of the account
    # syncs that work out its balances again, so a disabled copy the sync
    # empties or rebuilds (see EtoroAccount#processed_while_disabled?) is
    # synced on its own.
    def sync_disabled_account
      account.sync_later if account.disabled?
    end

    # What the syncs wrote on a copy's account: its eToro entries, among them
    # the balances recorded by hand that eToro's figures replaced (see
    # EtoroAccount::BalanceHistoryProcessor), and the reconciliations its
    # anchors of earlier days turned into, which come after the link and fall
    # on days Sure recorded the copy, as the anchors are set on sync days. A
    # balance recorded by hand on a day Sure never recorded the copy stays,
    # whenever it was recorded.
    def synced_entries
      recorded_days = etoro_account.positions_owner.portfolio_snapshots.where(mirror_id: etoro_account.mirror_id).select(:date)
      reconciliations = account.valuations.reconciliation
        .where(entries: { created_at: etoro_account.account_provider.created_at.., date: recorded_days })
      account.entries.where(source: "etoro").or(account.entries.where(entryable_type: "Valuation", entryable_id: reconciliations.select(:id)))
    end

    def account
      @account ||= etoro_account.current_account
    end

    def total_balance
      etoro_account.current_balance || 0
    end

    # One transaction, so a balance the anchor refuses leaves the account's
    # figures as they were too.
    def update_account_balance!(total = total_balance, cash: etoro_account.cash_balance || 0)
      account.transaction do
        account.assign_attributes(balance: total, cash_balance: cash, currency: etoro_account.currency)
        account.save!

        result = account.set_current_balance(total, schedule_sync: false)
        raise Provider::Etoro::Error, "Failed to set the current balance: #{result.error}" unless result.success?
      end
    end
end
