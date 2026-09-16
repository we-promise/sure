require "bigdecimal"
require "set"
require "time"

# This is the authorized database boundary for the pure classifier. It returns
# aggregates, effective settings and encrypted-state hints, never raw history.
class Ingestion::BalancePolicies::Simplefin::Snapshot
  DEFAULTS = {
    "window_days" => 120, "min_txns" => 10, "min_payments" => 2,
    "epsilon_base" => BigDecimal("0.50"), "statement_guard_days" => 5, "sticky_days" => 7
  }.freeze

  def self.configuration
    new(connection: nil, observed_at: Time.current).configuration
  end

  def configuration
    { "enabled" => @enabled, "settings" => @settings.deep_dup }
  end

  def self.build(connection:, observed_at:, external_accounts: nil, configuration: nil, key_by: :external_id)
    new(connection: connection, observed_at: observed_at, external_accounts: external_accounts, configuration: configuration, key_by: key_by).build
  end

  def initialize(connection:, observed_at:, external_accounts: nil, configuration: nil, key_by: :external_id)
    unless observed_at.is_a?(Time) || observed_at.is_a?(DateTime)
      raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "A fixed SimpleFIN observation timestamp is required"
    end
    @connection = connection
    @observed_at = observed_at.to_time
    @settings = configuration ? configuration.fetch("settings").deep_dup : effective_settings
    @enabled = configuration ? configuration.fetch("enabled") : enabled?
    @external_accounts, @key_by = external_accounts, key_by
    raise ArgumentError unless %i[id external_id].include?(key_by)
  end

  def build
    rows = @external_accounts || connection.external_accounts.where(family_id: connection.family_id).includes(:account).order(:id)
    rows.each_with_object({}) do |external, result|
      account = external.current_account
      next unless account && external.external_id.present?
      unless account.family_id == connection.family_id
        raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "SimpleFIN policy ownership differs"
      end
      key = external.public_send(@key_by)
      raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "SimpleFIN snapshot identity is ambiguous" if result.key?(key)
      result[key] = account_snapshot(external, account).merge("identity_namespace" => external.identity_namespace)
    end
  end

  # Preserve the original pre-publication entry counts, settings and sticky hint.
  # Only the sparse raw fallback advances after this Sync's transactions commit.
  def refresh_raw_history(external:, baseline:)
    account = external.current_account
    expected = { "schema_version" => 1, "account_id" => account&.id, "family_id" => connection.family_id,
      "external_account_id" => external.id, "identity_namespace" => external.identity_namespace,
      "account_type" => account&.accountable_type, "as_of" => observed_at.iso8601(9), "enabled" => @enabled, "settings" => settings }
    unless account && account.family_id == connection.family_id && baseline.is_a?(Hash) && baseline.slice(*expected.keys) == expected
      raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "SimpleFIN baseline belongs to another request"
    end
    result = baseline.deep_dup
    if @enabled && account.accountable_type == "CreditCard" && !fresh_hint?(baseline["sticky_hint"]) &&
        baseline.fetch("entry_metrics").fetch("tx_count") < settings.fetch("min_txns")
      mapping = ProviderMigrationMapping.find_by(external_account: external, role: "external_account", legacy_type: "SimplefinAccount")
      result["raw_metrics"] = raw_metrics(external, mapping)
    end
    result
  rescue KeyError, TypeError, NoMethodError
    raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "Invalid SimpleFIN classification baseline", cause: nil
  end

  private
    attr_reader :connection, :observed_at, :settings

    def account_snapshot(external, account)
      mapping = ProviderMigrationMapping.find_by(external_account: external, role: "external_account", legacy_type: "SimplefinAccount")
      hint, hint_source = stored_hint(external, mapping)
      active = @enabled
      entries = raw = nil
      if active && account.accountable_type == "CreditCard" && !fresh_hint?(hint)
        entries = entry_metrics(account)
        raw = raw_metrics(external, mapping) if entries.fetch("tx_count") < settings.fetch("min_txns")
      end
      {
        "schema_version" => 1, "enabled" => active, "account_type" => account.accountable_type,
        "account_id" => account.id, "family_id" => connection.family_id, "external_account_id" => external.id,
        "as_of" => observed_at.iso8601(9), "settings" => settings.deep_dup,
        "sticky_hint" => hint, "sticky_hint_source" => hint_source, "entry_metrics" => entries, "raw_metrics" => raw,
        "legacy_cache_namespace" => mapping && "simplefin:sfa:#{mapping.legacy_id}:liability_sign_hint"
      }
    end

    def enabled?
      configured = Setting["simplefin_cc_overpayment_detection"]
      return boolean(configured) unless configured.nil?
      value = ENV["SIMPLEFIN_CC_OVERPAYMENT_HEURISTIC"]
      value.present? ? boolean(value) : true
    end

    def boolean(value)
      value == true || (value.is_a?(String) && %w[1 true yes on].include?(value.downcase))
    end

    def effective_settings
      DEFAULTS.to_h do |key, fallback|
        value = Setting["simplefin_cc_overpayment_#{key}"].presence || fallback
        parsed = key == "epsilon_base" ? decimal_or_zero(value) : value.to_i
        acceptable = key == "statement_guard_days" ? parsed >= 0 : parsed > 0
        [ key, acceptable ? parsed : fallback ]
      end
    end

    def stored_hint(external, mapping)
      state = external.sensitive_details.dig("balance_policy_state", "simplefin")
      source = "encrypted_state" if state
      # Once a native hint exists (even if expired), never revive an older hint.
      if state.nil? && mapping
        state = Provider::AccountData::Simplefin::RetainedHint.read(connection: connection, external: external)
        source = "retained_migration" if state
      end
      return [ nil, nil ] unless state
      value = state.with_indifferent_access
      expires = value.fetch(:expires_at)
      expires = expires.iso8601(9) if expires.respond_to?(:iso8601)
      [ { "value" => value.fetch(:value).to_s, "expires_at" => expires }, source ]
    rescue KeyError, TypeError, NoMethodError
      raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "Invalid retained SimpleFIN policy hint", cause: nil
    end

    def fresh_hint?(hint)
      hint && Time.iso8601(hint.fetch("expires_at")) > observed_at
    rescue KeyError, TypeError, ArgumentError
      raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "Invalid retained SimpleFIN policy expiry", cause: nil
    end

    def entry_metrics(account)
      guard = ApplicationRecord.connection.quote(observed_at.to_date - settings.fetch("statement_guard_days"))
      values = account.entries.where("date >= ?", start_date).pick(
        Arel.sql("COUNT(*)"),
        Arel.sql("COALESCE(SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END), 0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN amount < 0 THEN -amount ELSE 0 END), 0)"),
        Arel.sql("COALESCE(SUM(CASE WHEN amount < 0 THEN 1 ELSE 0 END), 0)"),
        Arel.sql("COALESCE(BOOL_OR(amount < 0 AND date >= #{guard}), FALSE)")
      )
      {
        "tx_count" => values[0].to_i, "charges_total" => BigDecimal(values[1].to_s),
        "payments_total" => BigDecimal(values[2].to_s), "payments_count" => values[3].to_i,
        "recent_payment" => values[4] == true
      }
    end

    def raw_metrics(external, mapping)
      metrics = empty_metrics
      seen = Set.new
      sources = SourceRecord.where(family_id: connection.family_id, account_id: external.current_account.id,
        external_account: external, kind: "transaction")
      # One encrypted batch at a time bounds memory to an upstream response.
      IngestionBatch.where(id: sources.select(:ingestion_batch_id), family_id: connection.family_id,
        provider_connection: connection, external_account: external, origin_kind: "provider", stream: "transactions")
        .find_each(batch_size: 1) do |batch|
        observations = sources.where(ingestion_batch_id: batch.id).pluck(:input_external_id, :withdrawn).to_h
        seen.merge(observations.keys)
        records = Ingestion::Codec.load(batch.payload).records
        found = Set.new
        records.each do |record|
          next unless observations.key?(record[:external_id])
          next unless found.add?(record[:external_id])
          next if observations.fetch(record[:external_id])
          date = (record[:metadata] || {}).with_indifferent_access[:liability_policy_date]
          unless date.is_a?(String)
            raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "Source observation lacks liability date provenance"
          end
          accumulate(metrics, amount: record[:amount], date: Date.iso8601(date))
        end
        unless (observations.reject { |_, withdrawn| withdrawn }.keys - found.to_a).empty?
          raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "Source observation is missing from retained evidence"
        end
      end
      if mapping
        control = mapping.provider_migration_control
        unless mapping.family_id == connection.family_id && control.provider_connection_id == connection.id
          raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "Migration evidence ownership differs"
        end
        copier = Provider::AccountData::MigrationCopier.new(provider_key: "simplefin", legacy_item_id: control.legacy_id)
        row = copier.snapshot_for(mapping)
        Array(row.fetch("attributes").fetch("raw_transactions_payload")).each do |raw|
          next unless raw.is_a?(Hash)
          values = raw.with_indifferent_access
          next if values[:id].present? && seen.include?("simplefin_#{values[:id]}")
          date = ::Simplefin::DateUtils.parse_provider_date(values[:posted]) || ::Simplefin::DateUtils.parse_provider_date(values[:transacted_at])
          accumulate(metrics, amount: -decimal_or_zero(values[:amount]), date: date) if date
        end
      end
      metrics
    rescue KeyError, TypeError, ArgumentError
      raise Ingestion::BalancePolicies::Simplefin::InvalidSnapshot, "Invalid retained SimpleFIN history", cause: nil
    end

    def start_date
      observed_at.to_date - settings.fetch("window_days")
    end

    def empty_metrics
      { "tx_count" => 0, "charges_total" => BigDecimal("0"), "payments_total" => BigDecimal("0"),
        "payments_count" => 0, "recent_payment" => false }
    end

    def accumulate(metrics, amount:, date:)
      return if date < start_date
      metrics["tx_count"] += 1
      if amount.positive?
        metrics["charges_total"] += amount
      elsif amount.negative?
        metrics["payments_total"] -= amount
        metrics["payments_count"] += 1
        metrics["recent_payment"] ||= date >= observed_at.to_date - settings.fetch("statement_guard_days")
      end
    end

    def decimal_or_zero(value)
      return BigDecimal("0") unless value.is_a?(String) || value.is_a?(Numeric)
      parsed = BigDecimal(value.to_s)
      parsed.finite? ? parsed : BigDecimal("0")
    rescue ArgumentError
      BigDecimal("0")
    end
end
