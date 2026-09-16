require "bigdecimal"
require "time"

# Pure evaluation of captured inputs. A runtime context collector owns family
# authorization, configuration, history aggregation and retained sticky hints.
# Store its snapshot and this result in encrypted batch evidence before applying
# a balance; retries must evaluate that evidence instead of querying live state.
class Ingestion::BalancePolicies::Simplefin
  class InvalidSnapshot < StandardError; end

  VERSION = 1
  Result = Data.define(:classification, :reason, :metrics)
  SETTINGS = %w[window_days min_txns min_payments epsilon_base statement_guard_days sticky_days].freeze
  METRICS = %w[tx_count charges_total payments_total payments_count recent_payment].freeze

  def initialize(snapshot:)
    raise InvalidSnapshot, "Expected a SimpleFIN policy snapshot" unless snapshot.is_a?(Hash)
    @snapshot = snapshot.deep_stringify_keys
    unless @snapshot["schema_version"] == VERSION && [ true, false ].include?(@snapshot["enabled"])
      raise InvalidSnapshot, "Unsupported SimpleFIN policy snapshot"
    end
    @now = Time.iso8601(@snapshot.fetch("as_of"))
    @settings = @snapshot.fetch("settings")
    validate_settings!
  rescue KeyError, TypeError, ArgumentError
    raise InvalidSnapshot, "Invalid SimpleFIN policy snapshot", cause: nil
  end

  def call(observed_balance:)
    observed = decimal(observed_balance)
    return unknown("flag disabled") unless snapshot.fetch("enabled")
    return unknown("no-account") unless snapshot["account_type"]
    return unknown("not-liability") unless %w[CreditCard Loan].include?(snapshot["account_type"])
    return unknown("near-zero-balance") if observed.abs <= decimal(settings.fetch("epsilon_base"))

    if (hint = sticky_hint)
      return Result.new(classification: hint, reason: "sticky_hint", metrics: {}.freeze)
    end

    entries = validate_metrics(snapshot["entry_metrics"])
    selected = if entries && entries.fetch("tx_count") >= settings.fetch("min_txns")
      entries
    else
      validate_metrics(snapshot["raw_metrics"])
    end
    return unknown("insufficient-txns") unless selected && selected.fetch("tx_count") >= settings.fetch("min_txns")

    metrics = selected.symbolize_keys.merge(
      net: selected.fetch("charges_total") - selected.fetch("payments_total"),
      observed: observed, window_days: settings.fetch("window_days")
    ).freeze
    classification, reason = classify(metrics)
    Result.new(classification: classification, reason: reason, metrics: metrics)
  end

  private
    attr_reader :snapshot, :settings, :now

    def validate_settings!
      raise InvalidSnapshot, "Invalid SimpleFIN policy settings" unless settings.is_a?(Hash) && (SETTINGS - settings.keys).empty?
      %w[window_days min_txns min_payments sticky_days].each do |key|
        value = settings.fetch(key)
        raise InvalidSnapshot, "Invalid SimpleFIN policy limits" unless value.is_a?(Integer) && value.positive?
      end
      %w[statement_guard_days].each do |key|
        value = settings.fetch(key)
        raise InvalidSnapshot, "Invalid SimpleFIN policy limits" unless value.is_a?(Integer) && value >= 0
      end
      raise InvalidSnapshot, "Invalid SimpleFIN policy epsilon" unless decimal(settings.fetch("epsilon_base")).positive?
    end

    def validate_metrics(value)
      return nil if value.nil?
      unless value.is_a?(Hash) && (METRICS - value.keys).empty?
        raise InvalidSnapshot, "Incomplete SimpleFIN history metrics"
      end
      result = value.slice(*METRICS)
      %w[tx_count payments_count].each do |key|
        number = result.fetch(key)
        raise InvalidSnapshot, "Invalid SimpleFIN history counts" unless number.is_a?(Integer) && number >= 0
      end
      if result.fetch("payments_count") > result.fetch("tx_count") || ![ true, false ].include?(result.fetch("recent_payment"))
        raise InvalidSnapshot, "Inconsistent SimpleFIN history metrics"
      end
      %w[charges_total payments_total].each do |key|
        result[key] = decimal(result.fetch(key))
        raise InvalidSnapshot, "Invalid SimpleFIN history amount" if result[key].negative?
      end
      result
    end

    def sticky_hint
      hint = snapshot["sticky_hint"]
      return nil if hint.nil?
      unless hint.is_a?(Hash) && %w[credit debt].include?(hint["value"])
        raise InvalidSnapshot, "Invalid SimpleFIN sticky hint"
      end
      expires = Time.iso8601(hint.fetch("expires_at"))
      hint.fetch("value").to_sym if expires > now
    rescue KeyError, TypeError, ArgumentError
      raise InvalidSnapshot, "Invalid SimpleFIN sticky expiry", cause: nil
    end

    def classify(metrics)
      if metrics.fetch(:recent_payment) && metrics.fetch(:payments_count) <= 2
        return [ :unknown, "statement-guard" ]
      end
      observed = metrics.fetch(:observed).abs
      epsilon = [ decimal(settings.fetch("epsilon_base")), observed * BigDecimal("0.005") ].max
      tolerance = [ BigDecimal("5"), observed * BigDecimal("0.10") ].max
      if (metrics.fetch(:net).abs - observed).abs > tolerance
        return [ :unknown, "net-balance-mismatch" ]
      end
      if metrics.fetch(:payments_total) - metrics.fetch(:charges_total) >= observed - epsilon
        return [ :credit, "payments>=charges+observed-eps" ]
      end
      if metrics.fetch(:net) > epsilon && metrics.fetch(:payments_count) >= settings.fetch("min_payments")
        return [ :debt, "charges>payments+eps" ]
      end
      [ :unknown, "ambiguous" ]
    end

    def decimal(value)
      unless value.is_a?(String) || value.is_a?(BigDecimal) || value.is_a?(Integer)
        raise InvalidSnapshot, "SimpleFIN policy requires exact decimal values"
      end
      result = BigDecimal(value.to_s)
      raise InvalidSnapshot, "SimpleFIN policy requires finite values" unless result.finite?
      result
    rescue ArgumentError
      raise InvalidSnapshot, "Invalid SimpleFIN policy amount", cause: nil
    end

    def unknown(reason)
      Result.new(classification: :unknown, reason: reason, metrics: {}.freeze)
    end
end
