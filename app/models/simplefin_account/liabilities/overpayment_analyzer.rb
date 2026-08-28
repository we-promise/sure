# frozen_string_literal: true

# Classifies a SimpleFIN liability balance as :debt (owe, show positive)
# or :credit (overpaid, show negative) using recent transaction history.
#
# Notes:
# - Preferred signal: already-imported Entry records for the linked Account
#   (they are in Maybe's convention: expenses/charges > 0, payments < 0).
# - Fallback signal: provider raw transactions payload with amounts converted
#   to Maybe convention by negating SimpleFIN's banking convention.
# - Returns :unknown when evidence is insufficient; callers should fallback
#   to existing sign-only normalization.
class SimplefinAccount::Liabilities::OverpaymentAnalyzer
  include SimplefinNumericHelpers
  Result = Struct.new(:classification, :reason, :metrics, keyword_init: true)

  DEFAULTS = {
    window_days: 120,
    min_txns: 10,
    min_payments: 2,
    epsilon_base: BigDecimal("0.50"),
    statement_guard_days: 5,
    sticky_days: 7
  }.freeze

  def initialize(simplefin_account, observed_balance:, now: Time.current)
    @sfa = simplefin_account
    @observed = to_decimal(observed_balance)
    @now = now
  end

  def call
    return unknown("flag disabled") unless enabled?
    return unknown("no-account") unless (account = @sfa.current_account)

    # Only applicable for liabilities
    return unknown("not-liability") unless %w[CreditCard Loan].include?(account.accountable_type)

    # Near-zero observed balances are too noisy to infer
    return unknown("near-zero-balance") if @observed.abs <= epsilon_base

    # Sticky cache via Rails.cache to avoid DB schema changes
    sticky = read_sticky
    if sticky && sticky[:expires_at] > @now
      return Result.new(classification: sticky[:value].to_sym, reason: "sticky_hint", metrics: {})
    end

    txns = gather_transactions(account)
    return unknown("insufficient-txns") if txns.size < min_txns

    metrics = compute_metrics(txns)
    cls, reason = classify(metrics)

    if %i[credit debt].include?(cls)
      write_sticky(cls)
    end

    Result.new(classification: cls, reason: reason, metrics: metrics)
  end

  private

    def enabled?
      # Setting override takes precedence, then ENV, then default enabled
      setting_val = Setting["simplefin_cc_overpayment_detection"]
      return parse_bool(setting_val) unless setting_val.nil?

      env_val = ENV["SIMPLEFIN_CC_OVERPAYMENT_HEURISTIC"]
      return parse_bool(env_val) if env_val.present?

      true # Default enabled
    end

    def parse_bool(value)
      case value
      when true, false then value
      when String then %w[1 true yes on].include?(value.downcase)
      else false
      end
    end

    def window_days
      val = Setting["simplefin_cc_overpayment_window_days"]
      v = (val.presence || DEFAULTS[:window_days]).to_i
      v > 0 ? v : DEFAULTS[:window_days]
    end

    def min_txns
      val = Setting["simplefin_cc_overpayment_min_txns"]
      v = (val.presence || DEFAULTS[:min_txns]).to_i
      v > 0 ? v : DEFAULTS[:min_txns]
    end

    def min_payments
      val = Setting["simplefin_cc_overpayment_min_payments"]
      v = (val.presence || DEFAULTS[:min_payments]).to_i
      v > 0 ? v : DEFAULTS[:min_payments]
    end

    def epsilon_base
      val = Setting["simplefin_cc_overpayment_epsilon_base"]
      d = to_decimal(val.presence || DEFAULTS[:epsilon_base])
      d > 0 ? d : DEFAULTS[:epsilon_base]
    end

    def statement_guard_days
      val = Setting["simplefin_cc_overpayment_statement_guard_days"]
      v = (val.presence || DEFAULTS[:statement_guard_days]).to_i
      v >= 0 ? v : DEFAULTS[:statement_guard_days]
    end

    def sticky_days
      val = Setting["simplefin_cc_overpayment_sticky_days"]
      v = (val.presence || DEFAULTS[:sticky_days]).to_i
      v > 0 ? v : DEFAULTS[:sticky_days]
    end

    def gather_transactions(account)
      start_date = (@now.to_date - window_days.days)

      # Prefer materialized entries
      entries = account.entries.where("date >= ?", start_date).select(:amount, :date)
      txns = entries.map { |e| { amount: to_decimal(e.amount), date: e.date } }
      return txns if txns.size >= min_txns

      # Fallback: provider raw payload
      raw = Array(@sfa.raw_transactions_payload)
      raw_txns = raw.filter_map do |tx|
        h = tx.with_indifferent_access
        amt = convert_provider_amount(h[:amount])
        d = (
          Simplefin::DateUtils.parse_provider_date(h[:posted]) ||
          Simplefin::DateUtils.parse_provider_date(h[:transacted_at])
        )
        next nil unless d
        next nil if d < start_date
        { amount: amt, date: d }
      end
      raw_txns
    rescue => e
      Rails.logger.debug("SimpleFIN transaction gathering failed for sfa=#{@sfa.id}: #{e.class} - #{e.message}")
      []
    end

    def compute_metrics(txns)
      charges = BigDecimal("0")
      payments = BigDecimal("0")
      payments_count = 0
      recent_payment = false
      guard_since = (@now.to_date - statement_guard_days.days)

      txns.each do |t|
        amt = to_decimal(t[:amount])
        if amt.positive?
          charges += amt
        elsif amt.negative?
          payments += -amt
          payments_count += 1
          recent_payment ||= (t[:date] >= guard_since)
        end
      end

      net = charges - payments
      {
        charges_total: charges,
        payments_total: payments,
        payments_count: payments_count,
        tx_count: txns.size,
        net: net,
        observed: @observed,
        window_days: window_days,
        recent_payment: recent_payment
      }
    end

    def classify(m)
      # Boundary guard: a single very recent payment may create temporary credit before charges post
      if m[:recent_payment] && m[:payments_count] <= 2
        return [ :unknown, "statement-guard" ]
      end

      eps = [ epsilon_base, (@observed.abs * BigDecimal("0.005")) ].max
      net = m[:charges_total] - m[:payments_total]

      # Sanity check: if transaction net is way off from observed balance, data is likely incomplete
      # (e.g., pending charges not in history yet). Use 10% tolerance or minimum $5.
      # Note: SimpleFIN always sends negative for liabilities, so we compare magnitudes only.
      tolerance = [ BigDecimal("5"), @observed.abs * BigDecimal("0.10") ].max
      if (net.abs - @observed.abs).abs > tolerance
        return [ :unknown, "net-balance-mismatch" ]
      end

      # Overpayment (credit): payments exceed charges by at least the observed balance (within eps)
      if (m[:payments_total] - m[:charges_total]) >= (@observed.abs - eps)
        return [ :credit, "payments>=charges+observed-eps" ]
      end

      # Debt: charges exceed payments beyond epsilon
      if (m[:charges_total] - m[:payments_total]) > eps && m[:payments_count] >= min_payments
        return [ :debt, "charges>payments+eps" ]
      end

      [ :unknown, "ambiguous" ]
    end

    def convert_provider_amount(val)
      amt = case val
      when String then BigDecimal(val) rescue BigDecimal("0")
      when Numeric then BigDecimal(val.to_s)
      else BigDecimal("0")
      end
      # Negate to convert banking convention (expenses negative) -> Maybe convention
      -amt
    end

    def read_sticky
      Rails.cache.read(sticky_key)
    end

    def write_sticky(value)
      Rails.cache.write(sticky_key, { value: value.to_s, expires_at: @now + sticky_days.days }, expires_in: sticky_days.days)
    end

    def sticky_key
      id = @sfa.id || "tmp:#{@sfa.object_id}"
      "simplefin:sfa:#{id}:liability_sign_hint"
    end

    # numeric coercion handled by SimplefinNumericHelpers#to_decimal

    def unknown(reason)
      Result.new(classification: :unknown, reason: reason, metrics: {})
    end
end
