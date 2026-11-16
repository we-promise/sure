# Checks each bill due in the next HORIZON_DAYS against the one account that
# pays it: that account's balance today, minus the other scheduled payments
# leaving it by the due date, plus the scheduled income and transfers
# arriving in it by then. When what is left will not cover the bill, the
# insight says so and by how much.
#
# CashFlowWarningGenerator answers a different question: whether the family's
# combined cash dips low over 30 days, with a spending baseline on top. A
# family can pass that check comfortably and still have rent leave an account
# that holds only a fraction of it; this is the per-account check.
#
# Only Depository accounts pay bills here, and only while their balance is
# current: a linked account's last synced balance, or a manual account with
# recent activity. A stale balance says nothing about the due date.
class Insight::Generators::BillNotCoveredGenerator < Insight::Generator
  produces "bill_not_covered"

  HORIZON_DAYS = 14
  BALANCE_MAX_AGE_DAYS = 5

  Flow = Data.define(:occurrence, :due_on, :amount, :bill)

  def generate
    accounts = paying_accounts
    return [] if accounts.empty?

    flows = flows_by_account(accounts)

    accounts.filter_map do |account|
      first_uncovered_bill(account, flows.fetch(account.id, []))
    end
  end

  private
    # Bills in date order; the first the account cannot cover is reported.
    # Later bills on the same account wait their turn, so one short account is
    # one card rather than a card for every bill behind the first.
    def first_uncovered_bill(account, flows)
      flows.select(&:bill).sort_by { |flow| [ flow.due_on, flow.occurrence.id ] }.each do |bill|
        others_by_then = flows.select { |flow| !flow.equal?(bill) && flow.due_on <= bill.due_on }
        available = account.balance.to_d + others_by_then.sum(&:amount)
        bill_amount = -bill.amount
        next if available >= bill_amount

        return build_bill_insight(account, bill, bill_amount, bill_amount - available)
      end

      nil
    end

    def build_bill_insight(account, bill, bill_amount, shortfall)
      name = bill.occurrence.recurring_transaction.display_name

      build_insight(
        insight_type: "bill_not_covered",
        priority: "high",
        title: I18n.t("insights.titles.bill_not_covered", account: account.name, name: name),
        template_key: "bill_not_covered",
        facts: {
          name: name,
          amount: format_money(bill_amount),
          due_on: I18n.l(bill.due_on),
          account: account.name,
          shortfall: format_money(shortfall)
        },
        # The shortfall moves with every transaction and stays a display fact:
        # one card, and one push, per occurrence. A new due date (a snooze) is
        # a new situation and resurfaces it.
        metadata: {
          account_id: account.id,
          recurring_occurrence_id: bill.occurrence.id,
          due_on: bill.due_on.iso8601
        },
        dedup_key: "bill_not_covered:#{bill.occurrence.id}"
      )
    end

    # The insight names the account to the whole family, so only accounts
    # every active member can see qualify. Credit cards have no balance that
    # "covers" a charge, so they never count as the paying account. Family
    # currency only, like the amounts the card formats.
    def paying_accounts
      candidates = family.accounts.visible.accessible_by_all_active_members
                         .where(accountable_type: "Depository", currency: family.currency).to_a
      return [] if candidates.empty?

      balance_dates = balance_dates_for(candidates)
      cutoff = Date.current - BALANCE_MAX_AGE_DAYS

      candidates.select do |account|
        balance_date = balance_dates[account.id]
        balance_date.present? && balance_date >= cutoff
      end
    end

    # The day each balance was last known to be right. A linked account's is
    # the date of the balance its provider last reported (the current anchor),
    # which stops moving when syncs stop succeeding. A manual account has no
    # provider, so its latest entry stands in: a ledger nobody touched for
    # weeks is not a balance to promise a due date on.
    def balance_dates_for(accounts)
      ids = accounts.map(&:id)
      linked_ids = Account.linked.where(id: ids).pluck(:id)

      anchors = Valuation.current_anchor.joins(:entry)
                         .where(entries: { account_id: linked_ids })
                         .group("entries.account_id").maximum("entries.date")
      activity = Entry.where(account_id: ids - linked_ids).excluding_scheduled
                      .group(:account_id).maximum(:date)

      anchors.merge(activity)
    end

    # Every open occurrence that moves money in or out of a paying account
    # before the horizon closes, as signed flows per account: negative leaves
    # the account, positive arrives. A transfer between two paying accounts is
    # a flow on both. Only flows in the account's own currency can be added
    # to its balance without a rate.
    def flows_by_account(accounts)
      by_id = accounts.index_by(&:id)
      occurrences = upcoming_occurrences(by_id.keys)
      payable_ids = family.recurring_transactions.payable
                          .where(id: occurrences.map(&:recurring_transaction_id)).pluck(:id).to_set

      occurrences.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |occurrence, flows|
        series = occurrence.recurring_transaction
        remaining = occurrence.remaining_amount
        next unless remaining.positive?

        due_today = occurrence.effective_due_on == Date.current

        add = ->(account_id, amount, bill: false) do
          account = by_id[account_id]
          next unless account && account.currency == occurrence.currency
          # Money due out today may already be in the balance; money due in
          # today and still open has not been seen by the day's sync yet.
          next if due_today && amount.negative?

          flows[account_id] << Flow.new(occurrence: occurrence, due_on: occurrence.effective_due_on, amount: amount, bill: bill)
        end

        if series.amount.negative?
          add.(series.account_id, remaining)
        else
          add.(series.account_id, -remaining, bill: payable_ids.include?(series.id))
          add.(series.destination_account_id, remaining) if series.destination_account_id
        end
      end
    end

    # From today (see flows_by_account for what counts on the day). Past-due
    # occurrences are left out: paid but unmatched or still to go, the balance
    # cannot tell. A snoozed bill counts on the date it was snoozed to; an
    # autopay bill the bank takes early is matched to its payment, and a
    # matched occurrence is no longer open.
    def upcoming_occurrences(account_ids)
      RecurringOccurrence.preload_confirmed_allocated(
        family.recurring_occurrences
              .open_status
              .joins(:recurring_transaction)
              .where(recurring_transactions: { status: :active })
              .where("recurring_transactions.account_id IN (:ids) OR recurring_transactions.destination_account_id IN (:ids)", ids: account_ids)
              .where("#{RecurringOccurrence::EFFECTIVE_DUE_ON_SQL} BETWEEN ? AND ?", Date.current, Date.current + HORIZON_DAYS)
              .includes(recurring_transaction: :merchant)
              .to_a
      )
    end
end
