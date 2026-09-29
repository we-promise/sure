class Transfer::Creator
  # Raised when the submitted idempotency key already belongs to an entry,
  # but that entry's transfer doesn't match the current request (different
  # destination/amount/date) — i.e. a stale key from a cached form rather
  # than a genuine double-submit. See #find_existing_transfer.
  StaleIdempotencyKeyError = Class.new(StandardError)

  def initialize(family:, source_account_id:, destination_account_id:, date:, amount:, exchange_rate: nil, source_fee_amount: nil, destination_fee_amount: nil, tag_ids: nil, idempotency_key: nil)
    @family = family
    @source_account = family.accounts.find(source_account_id) # early throw if not found
    @destination_account = family.accounts.find(destination_account_id) # early throw if not found
    @date = date
    @amount = amount.to_d
    @source_fee_amount = source_fee_amount.to_d
    @destination_fee_amount = destination_fee_amount.to_d
    @tag_ids = Array(tag_ids).reject(&:blank?)
    @idempotency_key = idempotency_key

    if exchange_rate.present?
      rate_value = exchange_rate.to_d
      raise ArgumentError, "exchange_rate must be greater than 0" unless rate_value > 0
      @exchange_rate = rate_value
    else
      @exchange_rate = nil
    end
  end

  def create
    raise ArgumentError, "source_fee_amount must be non-negative" if source_fee_amount.negative?
    raise ArgumentError, "destination_fee_amount must be non-negative" if destination_fee_amount.negative?

    # Sequential double-submit guard: the form was already submitted
    # successfully once (double-click, browser retry, user reopening the
    # dialog after a slow response) and the first request already committed
    # by the time this one runs. Return the existing transfer instead of
    # creating a second, identical one.
    if idempotency_key && (existing_transfer = find_existing_transfer)
      return existing_transfer
    end

    transfer = Transfer.new(
      inflow_transaction: inflow_transaction,
      outflow_transaction: outflow_transaction,
      status: "confirmed",
      amount: amount
    )

    # requires_new: true opens a savepoint rather than joining whatever
    # transaction the caller may already be in, so a RecordNotUnique below
    # only rolls back this block, not any outer transaction - keeping the
    # retry lookup in the rescue usable instead of hitting
    # PG::InFailedSqlTransaction (see Account::ReconciliationManager for the
    # same fix applied to valuations, and the CodeRabbit/Codex findings that
    # prompted it).
    Transfer.transaction(requires_new: true) do
      if source_fee_amount > 0
        transfer.fee_transactions << build_source_fee_transaction
      end
      if destination_fee_amount > 0
        transfer.fee_transactions << build_destination_fee_transaction
      end
      transfer.save!
      apply_tags!(transfer) if tag_ids.any?
    end

    source_account.sync_later
    destination_account.sync_later

    transfer
  rescue ActiveRecord::RecordNotUnique
    # Concurrent-request backstop: two near-simultaneous submissions both
    # passed the pre-check above (neither saw the other's row yet) and both
    # reached #create. The partial unique index on entries(account_id,
    # idempotency_key) lets exactly one leg's INSERT win, which rolls back
    # this entire Transfer.transaction block (no half-created transfer left
    # behind). Return the winning transfer instead of creating a duplicate
    # or raising a raw DB error to the user.
    #
    # The INSERT hitting the unique index proves an entry with this key
    # already exists on source_account, but find_existing_transfer only
    # returns it when it matches the current request - so a nil here means
    # the key belongs to a *different*, stale request (e.g. a cached form
    # resubmitted with a new destination/amount/date), not a genuine retry.
    # Surface that distinctly instead of re-raising the raw DB error.
    existing_transfer = idempotency_key && find_existing_transfer
    raise StaleIdempotencyKeyError unless existing_transfer

    existing_transfer
  end

  private
    attr_reader :family, :source_account, :destination_account, :date, :amount, :exchange_rate, :source_fee_amount, :destination_fee_amount, :tag_ids, :idempotency_key

    # Scoped to source_account + idempotency_key so it only ever finds a
    # transfer this same key could plausibly refer to, but the key alone
    # isn't enough: a stale hidden field (Turbo Drive cache, reopened
    # dialog) can resubmit an old key for a request that's since changed
    # destination/amount/date. Verifying those fields against the request
    # keeps a genuinely different transfer from being silently discarded
    # in favor of returning the old one.
    def find_existing_transfer
      transfer = source_account.entries.find_by(idempotency_key: idempotency_key)&.entryable&.transfer
      return nil unless transfer
      return nil unless matches_request?(transfer)

      transfer
    end

    # Compares against every persisted effect of #create, not just accounts
    # and date/amount - a retry with the same key but a different
    # exchange_rate or fee would otherwise be reported as "success" while
    # silently keeping the old inflow amount and fee entries.
    #
    # inflow_converted_amount re-applies the current request's exchange_rate
    # (or re-fetches the rate for the same date, which is cached/stable) to
    # compare against what's actually persisted, rather than trying to
    # recover the original request's exchange_rate from stored state (it
    # isn't persisted anywhere - only its effect on the inflow amount is).
    # A rate that's no longer available on retry means this isn't a
    # same-request retry either, so treat that as a mismatch too and let the
    # normal create path surface the real Money::ConversionError.
    def matches_request?(transfer)
      outflow_entry = transfer.outflow_transaction.entry
      inflow_entry = transfer.inflow_transaction.entry

      outflow_entry.account_id == source_account.id &&
        inflow_entry.account_id == destination_account.id &&
        outflow_entry.date == date &&
        outflow_entry.amount == amount &&
        inflow_entry.amount == inflow_converted_amount * -1 &&
        transfer.derived_source_fee_amount == source_fee_amount &&
        transfer.derived_destination_fee_amount == destination_fee_amount
    rescue Money::ConversionError
      false
    end

    # Every leg gets a role-specific suffix except the outflow (find_existing_transfer
    # looks it up by the bare key). This matters because the unique index is
    # scoped per account_id, and the form doesn't prevent selecting the same
    # account as both source and destination - without distinct suffixes,
    # the inflow (and a fee leg sharing its primary leg's account) would
    # collide with another leg under that same account instead of with a
    # genuine duplicate submission. Deliberately its own column, not
    # external_id/source - see
    # db/migrate/20260902180400_add_idempotency_key_to_entries.rb for why
    # reusing those provider-linkage fields here would be wrong.
    def entry_idempotency_attrs(leg: :outflow)
      return {} unless idempotency_key

      key = leg == :outflow ? idempotency_key : "#{idempotency_key}-#{leg}"
      { idempotency_key: key }
    end

    def apply_tags!(transfer)
      resolved_ids = family.tags.where(id: tag_ids).pluck(:id)
      return if resolved_ids.empty?

      [ transfer.outflow_transaction, transfer.inflow_transaction ].each do |transaction|
        transaction.tag_ids = resolved_ids
      end
    end

    def outflow_transaction
      name = "#{name_prefix} to #{destination_account.name}"
      kind = outflow_transaction_kind

      Transaction.new(
        kind: kind,
        category: (investment_contributions_category if kind == "investment_contribution"),
        entry: source_account.entries.build(
          amount: amount,
          currency: source_account.currency,
          date: date,
          name: name,
          user_modified: true,
          **entry_idempotency_attrs(leg: :outflow)
        )
      )
    end

    def investment_contributions_category
      source_account.family.investment_contributions_category
    end

    def inflow_transaction
      name = "#{name_prefix} from #{source_account.name}"

      net_inflow = inflow_converted_amount

      Transaction.new(
        kind: "funds_movement",
        entry: destination_account.entries.build(
          amount: net_inflow * -1,
          currency: destination_account.currency,
          date: date,
          name: name,
          user_modified: true,
          **entry_idempotency_attrs(leg: :inflow)
        )
      )
    end

    def build_source_fee_transaction
      fee_category = find_or_create_fees_category(source_account.family)
      Transaction.new(
        kind: "standard",
        category: fee_category,
        entry: source_account.entries.build(
          amount: source_fee_amount,
          currency: source_account.currency,
          date: date,
          name: "Transfer fee — #{name_prefix} to #{destination_account.name}",
          **entry_idempotency_attrs(leg: :source_fee)
        )
      )
    end

    def build_destination_fee_transaction
      fee_category = find_or_create_fees_category(destination_account.family)
      Transaction.new(
        kind: "standard",
        category: fee_category,
        entry: destination_account.entries.build(
          amount: destination_fee_amount,
          currency: destination_account.currency,
          date: date,
          name: "Transfer fee — #{name_prefix} from #{source_account.name}",
          **entry_idempotency_attrs(leg: :destination_fee)
        )
      )
    end

    def find_or_create_fees_category(family)
      family.categories.find_or_create_by!(name: I18n.t("models.category.defaults.fees"))
    end

    def inflow_converted_amount
      Money.new(amount.abs, source_account.currency)
           .exchange_to(
             destination_account.currency,
             date: date,
             custom_rate: exchange_rate
           ).amount
    end

    def outflow_transaction_kind
      if destination_account.loan?
        "loan_payment"
      elsif destination_account.liability?
        "cc_payment"
      elsif destination_is_investment? && !source_is_investment?
        "investment_contribution"
      else
        "funds_movement"
      end
    end

    def destination_is_investment?
      destination_account.investment? || destination_account.crypto?
    end

    def source_is_investment?
      source_account.investment? || source_account.crypto?
    end

    def name_prefix
      if destination_account.liability?
        "Payment"
      else
        "Transfer"
      end
    end
end
