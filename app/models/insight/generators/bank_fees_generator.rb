# Adds up the fees each bank account was charged over the last 90 days:
# transactions in the default Fees category or its subcategories, refunds
# netted out. One insight per account, when the total reaches MIN_TOTAL or
# when the account charged a fee after charging none in the 90 days before
# (only for an account whose history covers those 90 days).
class Insight::Generators::BankFeesGenerator < Insight::Generator
  produces "bank_fees"

  # Known limitation: family-currency units, tuned for dollar/euro-scale
  # currencies (¥10 would flag almost any fee).
  MIN_TOTAL = 10
  WINDOW_DAYS = 90
  # Accounts a bank charges fees on. Brokerage and crypto fees are the cost of
  # trading, which the portfolio reports, not something the bank charged.
  ACCOUNT_TYPES = %w[Depository CreditCard Loan].freeze

  FeeTotals = Data.define(:account_id, :total, :charges, :latest_fee_id, :prior_charges, :first_fees) do
    alias_method :first_fees?, :first_fees
  end

  def generate
    category_ids = fee_category_ids
    return [] if category_ids.empty?

    fees = fee_entries(category_ids)
    totals = with_first_fees(fee_totals(fees)).select { |row| reportable?(row) }
    return [] if totals.empty?

    accounts = eligible_accounts.where(id: totals.map(&:account_id)).index_by(&:id)

    totals.filter_map do |row|
      account = accounts[row.account_id]
      next unless account

      build_insight(
        insight_type: "bank_fees",
        priority: row.first_fees? ? "medium" : "low",
        title: I18n.t("insights.titles.bank_fees", account: account.name),
        template_key: row.first_fees? ? "bank_fees.new" : "bank_fees.recurring",
        facts: {
          account: account.name,
          amount: format_money(row.total),
          count: row.charges,
          days: WINDOW_DAYS
        },
        # The total drifts as old fees roll out of the window; only a new fee
        # (or the account turning from "first fees" into a repeat) is a change
        # worth resurfacing an acknowledged card for. The fee recorded last
        # (not the one dated last) catches a second fee on the same day and a
        # fee imported late with an older date; it is read without a date
        # window, so a fee ageing out never passes for a new one.
        metadata: {
          account_id: account.id,
          latest_fee_id: row.latest_fee_id,
          new: row.first_fees?
        },
        period: Period.custom(start_date: window_start, end_date: Date.current),
        dedup_key: "bank_fees:#{account.id}"
      )
    end
  end

  private
    def reportable?(row)
      return false unless row.total.positive?

      row.total >= MIN_TOTAL || row.first_fees?
    end

    # The insight names the account and its fees to the whole family, so only
    # accounts every active member can see qualify.
    def eligible_accounts
      shared_accounts.visible.where(accountable_type: ACCOUNT_TYPES, currency: family.currency)
    end

    def fee_category_ids
      fees = family.categories.fees
      family.categories.where(id: fees).or(family.categories.where(parent_id: fees)).pluck(:id)
    end

    # Fee rows as the insight counts them, on accounts it may name.
    def fee_entries(category_ids)
      Transaction.joins(:entry)
        .excluding_pending
        .merge(Entry.excluding_split_parents)
        .where(category_id: category_ids)
        .where.not(kind: Transaction::TRANSFER_KINDS)
        .where(entries: { account_id: eligible_accounts.select(:id), excluded: false, currency: family.currency })
        .where("entries.date <= ?", Date.current)
    end

    # One grouped query over both windows: the current one is summed (so a
    # refunded fee nets out), the prior one only needs to know whether any fee
    # was charged at all.
    def fee_totals(fees)
      current = ActiveRecord::Base.sanitize_sql_array([ "entries.date >= ?", window_start ])
      latest_fee_ids = latest_fee_ids(fees)

      fees.where("entries.date >= ?", window_start - WINDOW_DAYS)
        .group("entries.account_id")
        .pluck(
          Arel.sql("entries.account_id"),
          Arel.sql("COALESCE(SUM(entries.amount) FILTER (WHERE #{current}), 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE #{current} AND entries.amount > 0)"),
          Arel.sql("COUNT(*) FILTER (WHERE NOT (#{current}) AND entries.amount > 0)")
        )
        .map do |account_id, total, charges, prior_charges|
          FeeTotals.new(account_id, total, charges, latest_fee_ids[account_id], prior_charges, false)
        end
    end

    # Each account's fee recorded last, whatever its date.
    def latest_fee_ids(fees)
      fees.where("entries.amount > 0")
        .group("entries.account_id")
        .pluck(Arel.sql("entries.account_id"), Arel.sql("(ARRAY_AGG(entries.id ORDER BY entries.created_at DESC, entries.id DESC))[1]"))
        .to_h
    end

    # "None in the 90 days before" only means something if the account was
    # there to be charged: a newly added account has no prior window at all.
    def with_first_fees(totals)
      history_starts = Entry.where(account_id: totals.map(&:account_id)).group(:account_id).minimum(:date)
      covered_since = window_start - WINDOW_DAYS

      totals.map do |row|
        history_start = history_starts[row.account_id]
        row.with(first_fees: row.prior_charges.zero? && history_start.present? && history_start <= covered_since)
      end
    end

    def window_start
      Date.current - WINDOW_DAYS
    end
end
