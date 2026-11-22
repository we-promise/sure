# Transactions for the Account Balances widget's transaction lane, loaded
# only when the viewer turns the lane on. Newest first and capped: when the
# cap cuts through a day, that day is dropped, and covered_from says from
# which day the items are complete. The widget fetches older days when the
# chart is zoomed into them.
class AccountBalanceTransactionsController < ApplicationController
  LIMIT = 5000

  def index
    response.headers["Cache-Control"] = "private, no-store"
    start_date, end_date = parse_date(params[:start_date]), parse_date(params[:end_date])
    unless start_date && end_date && start_date <= end_date
      return render json: { error: "invalid_period" }, status: :unprocessable_entity
    end

    entries = Entry.where(account_id: Current.user.accessible_accounts.visible.select(:id), entryable_type: "Transaction", date: start_date..end_date)
                   .includes(entryable: [ :category, :merchant ])
                   .order(date: :desc, id: :desc)
                   .limit(LIMIT + 1)
                   .to_a

    truncated = entries.size > LIMIT
    covered_from = start_date
    if truncated
      # The lookahead row tells whether the last kept day continues past the
      # cap: if it is from an older day, the last kept day is complete.
      last_kept, lookahead = entries[LIMIT - 1].date, entries[LIMIT].date
      entries = entries.first(LIMIT)
      if lookahead == last_kept
        entries = entries.reject { |entry| entry.date == last_kept }
        covered_from = last_kept + 1
      else
        covered_from = last_kept
      end
    end

    currency = Current.family.currency
    render json: { items: entries.map { |entry| entry_json(entry, currency) }, covered_from: covered_from.iso8601, truncated: truncated }
  end

  private
    def parse_date(value)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      date = Date.iso8601(value)
      date if date.year.positive?
    rescue Date::Error
      nil
    end

    # amount: the change to the account as charted (Sure stores outflows as
    # positive amounts), in the family currency, or nil when there is no
    # usable rate (left out of totals, like the chart); display: in the
    # entry's own currency.
    def entry_json(entry, currency)
      transaction = entry.entryable
      change = -entry.amount.to_d
      converted = if entry.currency == currency
        change
      else
        begin
          Money.new(change, entry.currency).exchange_to(currency, date: entry.date).amount
        rescue Money::ConversionError
          nil
        end
      end

      {
        id: entry.id,
        url: transaction_path(entry),
        date: entry.date.iso8601,
        account_id: entry.account_id,
        name: entry.name,
        amount: converted&.to_f&.round(2),
        display: Money.new(change, entry.currency).format,
        category: transaction.category&.name,
        category_color: transaction.category&.color,
        merchant: transaction.merchant&.name,
        kind: (transaction.kind unless transaction.standard?),
        excluded: entry.excluded,
        notes: entry.notes.presence&.truncate(140)
      }
    end
end
