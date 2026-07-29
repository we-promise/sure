# Posts the monthly interest charges that make a loan account behave like a real
# amortizing loan.
#
# Without this, a $849 mortgage payment transferred into a Loan account reduces
# the principal by the full $849 — Balance::BaseCalculator applies loan
# transactions straight to the non-cash balance. In reality most of an early
# mortgage payment services interest, and only the remainder pays down principal.
#
# Rather than rewriting the user's payment transaction (which would fight bank
# sync, the split machinery, and transfer matching), we post the other half of
# the ledger: a monthly "Interest charged" entry on the loan account itself,
# which *increases* the balance. The payment then nets down to principal only,
# exactly the way a lender's statement reads:
#
#   01 Jul  Interest charged        +833.33
#   01 Jul  Payment from Checking   -849.00
#   ------------------------------------------
#   Principal reduction              -15.67
#
# Accrual entries are marked `excluded: true`. Balance::SyncCache does not filter
# on `excluded`, so they still move the balance; IncomeStatement does filter on
# it, so the interest is not double-counted against the payment already booked as
# a `loan_payment` expense on the funding account.
#
# Interest is charged on the balance actually outstanding on the accrual date,
# not on a schedule projected from origination. Overpayments, missed payments and
# rate changes therefore self-correct on the next accrual, and the feature works
# for variable and adjustable rates as well as fixed.
class Loan::InterestAccrual
  # Written to `entries.source`, which combined with `external_id` is covered by
  # a unique index — that is what makes regeneration idempotent.
  SOURCE = "loan_interest_accrual"

  def initialize(loan)
    @loan = loan
    @account = loan.account
  end

  # Brings the generated accrual entries in line with the loan's current
  # configuration, creating, re-pricing and removing entries as needed.
  #
  # @return [Boolean] true when any entry was created, updated or destroyed
  def sync!
    return false if account.nil?

    # `accrues_interest?` covers the linked case too. If an account is later
    # linked, this reconciles to an empty set, purging the accruals it had
    # accumulated rather than leaving them to inflate a provider-anchored balance.
    reconcile(loan.accrues_interest? ? desired_accruals : [])
  end

  private
    attr_reader :loan, :account

    # Replays the account's ledger day by day, charging interest on the balance
    # outstanding at the start of each accrual date. We replay rather than read
    # the persisted Balance rows because this runs *before* balances are
    # materialized for the current sync, so those rows are a sync behind.
    #
    # The replay starts at the opening anchor because that is where a known
    # balance exists, but interest is only *charged* from the loan's configured
    # accrual start date. Those are not the same date: an account's opening
    # anchor is merely when its balance was first recorded, and
    # AccountableResource#create backdates it two years when the user doesn't
    # supply one. Charging from the anchor would invent years of debt the
    # borrower never incurred.
    def desired_accruals
      monthly_rate = loan.monthly_interest_rate
      return [] if monthly_rate.nil? || !monthly_rate.positive?

      replay_start = account.opening_anchor_date
      end_date = Date.current
      return [] if replay_start.nil? || replay_start >= end_date

      balance = valuation_amounts_by_date.fetch(replay_start, account.opening_anchor_balance.to_d)
      accruals = []

      replay_start.next_day.upto(end_date) do |date|
        # A valuation is an absolute reset (opening anchor or reconciliation). The
        # balance calculators discard same-day transactions on a valuation date,
        # so charging interest here would persist an entry with no balance effect
        # that still inflates the reported interest total. Skip the day entirely.
        if (valuation = valuation_amounts_by_date[date])
          balance = valuation
          next
        end

        # Charged before the day's own movements so that a payment landing on the
        # accrual date is applied to the balance *after* interest, not before.
        if chargeable_on?(date) && balance.positive?
          interest = (balance * monthly_rate).round(2)

          if interest.positive?
            accruals << { date: date, amount: interest }
            balance += interest
          end
        end

        balance += movement_amounts_by_date[date] if movement_amounts_by_date.key?(date)
      end

      accruals
    end

    # A charge lands on this date when it is a statement day AND at least one
    # whole month has elapsed since accrual began. Without the second condition a
    # start date of the 1st with a statement day of the 10th would charge a full
    # month's interest nine days in.
    def chargeable_on?(date)
      statement_day?(date) && date >= accrual_start_date.next_month
    end

    # Interest is charged on the same day of the month accrual began, unless the
    # user pinned a specific statement day. Clamped so a 31st falls on the last
    # day of shorter months.
    def statement_day?(date)
      date.day == [ accrual_day, date.end_of_month.day ].min
    end

    def accrual_day
      @accrual_day ||= loan.interest_accrual_day.presence || accrual_start_date.day
    end

    def accrual_start_date
      loan.interest_accrual_start_date
    end

    def valuation_amounts_by_date
      @valuation_amounts_by_date ||= account.entries
        .where(entryable_type: "Valuation")
        .includes(:entryable)
        .each_with_object({}) { |entry, amounts| amounts[entry.date] = converted_amount(entry) }
    end

    # Everything that moves the balance apart from valuations and our own
    # accruals. Split parents are skipped because their children carry the
    # amounts, matching Balance::SyncCache.
    def movement_amounts_by_date
      @movement_amounts_by_date ||= account.entries
        .where.not(entryable_type: "Valuation")
        # IS DISTINCT FROM rather than `where.not(source:)`, which would also
        # discard the NULL-source entries that manual and imported entries have.
        .where("entries.source IS DISTINCT FROM ?", SOURCE)
        .excluding_split_parents
        .includes(:entryable)
        .each_with_object(Hash.new(0.to_d)) { |entry, amounts| amounts[entry.date] += converted_amount(entry) }
    end

    # Mirrors Balance::SyncCache#converted_entries, including its use of a
    # transaction's user-supplied exchange rate. Without the custom rate the
    # replay's running balance would drift permanently from the materialized one
    # for any foreign-currency payment, and every later accrual with it.
    def converted_amount(entry)
      custom_rate = entry.entryable.exchange_rate if entry.entryable.respond_to?(:exchange_rate)

      entry.amount_money.exchange_to(
        account.currency,
        date: entry.date,
        custom_rate: custom_rate
      ).amount
    rescue Money::ConversionError
      entry.amount
    end

    def reconcile(desired)
      existing = account.entries.where(source: SOURCE).index_by(&:external_id)
      changed = false

      Entry.transaction do
        desired.each do |accrual|
          entry = existing.delete(external_id_for(accrual[:date]))

          if entry.nil?
            create_accrual(accrual)
            changed = true
          elsif (attrs = drifted_attributes(entry, accrual)).any?
            entry.update!(attrs)
            changed = true
          end
        end

        # Whatever is left is stale: the rate changed, the day moved, the loan was
        # paid off, or the user switched accrual back off.
        if existing.any?
          account.entries.where(id: existing.values.map(&:id)).destroy_all
          changed = true
        end
      end

      changed
    end

    # Every attribute of a generated entry is derived, so every one of them is
    # re-asserted. `excluded` in particular is load-bearing: it is what keeps the
    # charge out of IncomeStatement, and the transaction detail page offers users
    # a toggle for it. Left unrepaired, one flick of that toggle would
    # permanently double-count the interest against the loan payment. `date` and
    # `name` matter too — a family rule can rename these entries on every sync,
    # and an edited date desynchronizes the ledger from the replay that priced it.
    def drifted_attributes(entry, accrual)
      desired = {
        date: accrual[:date],
        amount: accrual[:amount],
        currency: account.currency,
        name: entry_name,
        excluded: true
      }

      desired.reject { |attribute, value| entry.public_send(attribute) == value }
    end

    def create_accrual(accrual)
      account.entries.create!(
        name: entry_name,
        date: accrual[:date],
        amount: accrual[:amount],
        currency: account.currency,
        excluded: true,
        source: SOURCE,
        external_id: external_id_for(accrual[:date]),
        entryable: Transaction.new(kind: "standard")
      )
    end

    # Keyed on the accrual *period* rather than the date, because the period is
    # what the entry actually represents: "the interest charge for 2026-02".
    #
    # This is what lets a statement-day or start-date change re-date the existing
    # entries in place instead of destroying and recreating every one of them —
    # on a long-lived loan that is the difference between ~340 updates and ~340
    # `dependent: :destroy` cascades followed by ~340 inserts.
    #
    # Safe because a charge fires at most once per calendar month; see the
    # "one accrual per period" test guarding that invariant.
    def external_id_for(date)
      date.strftime("%Y-%m")
    end

    # Frozen at creation and re-asserted on every sync, so a locale switch does
    # not churn every historical entry — the name is data, not presentation.
    def entry_name
      I18n.t("loans.interest_accrual.entry_name", locale: :en)
    end
end
