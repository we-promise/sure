# frozen_string_literal: true

# Reads a loan's rate from what the bank reported, and records a change in the
# one place a loan's rates live: `loans.variable_rate_schedule` (we-promise/sure#3891).
#
# THE DATE IS THE DAY IT WAS SEEN, and that is a limitation rather than a
# choice. `GET /v1/account-details` reports the rate in force right now and
# carries no effective date and no history -- neither `lendingRate` nor any
# entry in `lendingRates[]` has one, and the CDR standard behind it does not
# either. So a change detected on the 21st is recorded as the 21st even if the
# bank moved it on the 14th. Dating it earlier would be inventing a fact.
#
# `as_of` is INJECTED and never read from the clock in here. A sync that spans
# midnight, a replay, and a test all need the schedule keyed to the date the
# caller means, and a loan's figures are derived from those keys.
class RedbarkAccount::LoanDetailsProcessor
  SOURCE = "redbark"

  attr_reader :redbark_account, :as_of

  def initialize(redbark_account, as_of:)
    @redbark_account = redbark_account
    @as_of = as_of
  end

  def process
    return unless loan
    return if details.blank?
    return unless details_fetched_this_sync?

    apply_loan_terms
    apply_rate
  end

  private
    # A payload the sync did not refresh is a previous answer, not a current
    # one. Acting on it can record a change that never happened: the fetch
    # fails, the stored snapshot still holds last week's rate, the user has
    # since corrected the loan by hand, and the stale figure is written back
    # over their correction as though the bank had just reported it.
    #
    # Keyed to the sync's own date rather than to a duration, because `as_of`
    # is the only notion of "now" this class is allowed. RedbarkItem::Syncer
    # reads the clock ONCE and hands the same instant to the import that writes
    # this stamp and to the processing that supplies `as_of`, so the comparison
    # below is a clock against itself; two readings would make a sync that
    # crosses midnight reject the snapshot it had just stored. A second sync on
    # the same day after a failed fetch re-reads a snapshot that was fresh this
    # morning, which is harmless: the rate has not moved, so nothing is
    # recorded.
    def details_fetched_this_sync?
      fetched_at = redbark_account.account_details_fetched_at
      return false if fetched_at.blank?

      fetched_at.to_date == as_of.to_date
    end

    def account
      @account ||= redbark_account.current_account
    end

    def loan
      return @loan if defined?(@loan)

      @loan = account&.accountable_type == "Loan" ? account.accountable : nil
    end

    def details
      @details ||= redbark_account.raw_account_details_payload&.deep_symbolize_keys || {}
    end

    # The headline rate first, because it is the bank's own answer to "what is
    # this loan's rate". `lendingRates[]` is a product description: it can carry
    # several rate types, and `tiers` can split one of those into bands, so a
    # single figure cannot be pulled from it unless exactly one candidate
    # survives.
    def reported_rate
      return @reported_rate if defined?(@reported_rate)

      @reported_rate = to_percentage(details[:lendingRate]) || single_variable_rate
    end

    def single_variable_rate
      rates = details[:lendingRates]

      unless rates.is_a?(Array)
        # Not an error: a deposit account has no lending rates, and a bank that
        # reports none for a loan is "nothing to say", not "malformed". Only a
        # shape that is neither absent nor an array is worth a line.
        capture("Redbark account details carried no usable lendingRates", shape: rates.class.name) unless rates.nil?
        return nil
      end

      candidates = rates.select { |entry| entry.is_a?(Hash) && entry[:rateType].to_s.casecmp("VARIABLE").zero? }
      # A tiered rate is several rates wearing one entry: which band applies
      # depends on the balance, and the payload does not say which one the
      # account sits in.
      candidates = candidates.reject { |entry| Array(entry[:tiers]).any? }

      if candidates.size > 1
        capture("Redbark reported several variable rates; recording none", candidate_count: candidates.size)
        return nil
      end

      to_percentage(candidates.first&.dig(:rate))
    end

    # The API reports fractions: "0.0675" is 6.75%. The schedule and
    # `interest_rate` are both percentages.
    def to_percentage(value)
      return nil if value.blank?

      decimal = BigDecimal(value.to_s)
      # THREE decimal places, so a rate reads the same on every sync and what
      # is stored is what is compared. A bank reporting 0.064994 one sync and
      # 0.064996 the next would otherwise record a new row each time for a
      # movement of a hundredth of a basis point.
      rate = (decimal * 100).round(3)
      # The loan form caps a rate at Loan::MAX_INTEREST_RATE, and the model does
      # not check a schedule written any other way. A bank reporting 150% has
      # sent something other than a rate.
      return rate if rate.between?(0, Loan::MAX_INTEREST_RATE)

      capture("Redbark reported a rate outside 0..#{Loan::MAX_INTEREST_RATE}%; ignoring it", value: value.to_s)
      nil
    rescue ArgumentError, TypeError
      capture("Redbark reported an unparseable rate", value: value.to_s)
      nil
    end

    def apply_rate
      return if reported_rate.nil?

      adopt_rate_type_if_blank

      unless loan.variable_rate_type?
        # A fixed loan's rate does not move, so a bank reporting a different one
        # is a disagreement to surface, not a change to record. Nothing is
        # written -- not the schedule, not `interest_rate`, not `rate_type`.
        if loan.interest_rate.present? && BigDecimal(loan.interest_rate.to_s) != reported_rate
          capture(
            "Redbark reported a rate for a fixed loan; recording nothing",
            loan_id: loan.id, reported: reported_rate.to_s, recorded: loan.interest_rate.to_s
          )
        end
        return
      end

      return if record_first_sighting
      record_change
    end

    # A loan whose rate was never recorded is not a loan whose rate just moved.
    # Setting the base rate is the honest reading; a schedule row would claim a
    # change happened on a day nothing is known to have happened.
    def record_first_sighting
      return false if loan.interest_rate.present?

      write({ interest_rate: reported_rate })
      true
    end

    def record_change
      in_force = loan.current_variable_rate(as_of)
      return if in_force.present? && BigDecimal(in_force.to_s) == reported_rate

      schedule = (loan.variable_rate_schedule || {}).stringify_keys
      key = as_of.to_date.iso8601
      return if schedule.key?(key) && BigDecimal(schedule[key].to_s) == reported_rate

      write({ variable_rate_schedule: schedule.merge(key => reported_rate.to_s) })
    end

    # `rate_type` is blank on a loan nobody has classified. A bank calling its
    # own product VARIABLE is better evidence than silence, and without this the
    # rate is read and then dropped, since only a variable loan keeps a schedule.
    def adopt_rate_type_if_blank
      return if loan.rate_type.present?
      return unless bank_says_variable?

      write({ rate_type: "variable" })
    end

    def bank_says_variable?
      Array(details[:lendingRates]).any? do |entry|
        entry.is_a?(Hash) && entry[:rateType].to_s.casecmp("VARIABLE").zero?
      end
    end

    # Each filled only when blank: these describe the loan as it was written,
    # and a value already on the record is either the user's or an earlier
    # provider's. `enrich_attributes` skips locked attributes on its own.
    def apply_loan_terms
      terms = details[:loanDetails]
      return unless terms.is_a?(Hash)

      attrs = {}
      attrs[:start_date] = parse_date(terms[:originalStartDate]) if loan.start_date.blank?
      attrs[:initial_balance] = parse_decimal(terms[:originalLoanAmount]) if loan.initial_balance.blank?

      if loan.term_months.blank?
        months = term_months_between(terms[:originalStartDate], terms[:loanEndDate])
        attrs[:term_months] = months if months
      end

      attrs.compact!
      write(attrs) if attrs.any?
    end

    def term_months_between(start_value, end_value)
      from = parse_date(start_value)
      to = parse_date(end_value)
      return nil if from.nil? || to.nil? || to <= from

      months = ((to.year - from.year) * 12) + (to.month - from.month)
      return nil unless months.positive?

      # The longest term the loan form accepts. A bank reporting an end date
      # centuries out is reporting a placeholder, and a term of 13,200 months
      # is not something to store as though it were the loan's.
      months <= Loan::Simulator::MAX_PERIODS ? months : nil
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue Date::Error
      capture("Redbark reported an unparseable date", value: value.to_s)
      nil
    end

    def parse_decimal(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Every write goes through Enrichable: it skips locked attributes, records
    # provenance as a DataEnrichment, and calls `save` rather than `save!`, so a
    # value the model refuses -- a rate outside 0..100, say -- returns false
    # instead of raising and taking the sync with it.
    #
    # `false` alone is NOT a failure. Enrichable also returns it when every
    # attribute was locked or already held the value, which are the ordinary
    # quiet paths (rows 3 and 5). Only a populated `errors` distinguishes a
    # refusal from a no-op, and logging on `false` alone would put a warning in
    # the debug log every time a user's lock did exactly its job.
    def write(attrs)
      return if attrs.blank?

      loan.enrich_attributes(attrs, source: SOURCE)
      return if loan.errors.empty?

      capture(
        "Redbark loan detail refused by the model",
        loan_id: loan.id,
        attributes: attrs.keys.map(&:to_s),
        errors: loan.errors.full_messages
      )

      # A refusal is not tidied up by Enrichable: it assigns, calls `save`, and
      # when `save` returns false the REJECTED VALUES ARE STILL ON THE LOAN and
      # its errors are still populated. Terms are applied before the rate, so a
      # bank reporting an absurd `loanEndDate` would leave an out-of-range
      # `term_months` assigned, the rate write would then be refused for the
      # term rather than for the rate, and the loan would lose a rate change it
      # had every right to. The log would name the rate attributes and carry
      # the term's errors, which is how it would be misread.
      #
      # Clearing the errors matters on its own: `enrich_attributes` returns
      # early without saving when every attribute is locked or unchanged, so a
      # later no-op write would find these errors still sitting there and
      # report a refusal that did not happen.
      loan.restore_attributes(attrs.keys.map(&:to_s))
      loan.errors.clear
    end

    def capture(message, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: message,
        source: self.class.name,
        provider_key: "redbark",
        family: redbark_account.redbark_item&.family,
        metadata: metadata.merge(redbark_account_id: redbark_account.id)
      )
    end
end
