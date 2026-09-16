require "openssl"

# Evidence for the exact normalization context supplied to a factory. Live
# identity/configuration is revalidated; retained history is an explicit frozen
# baseline. Evidence contains keyed fingerprints, never credential/config values.
class Provider::AccountData::RuntimeInputs
  VERSION = 1
  MAX_ACCOUNTS = 10_000
  MAX_STORED_BYTES = 96 * 1024 * 1024
  MAX_INPUT_BYTES = 96 * 1024 * 1024
  MAX_NODES = 1_000_000
  BASE_FIELDS = %w[id external_id identity_namespace authorization_ids linked_account].freeze
  TOP_LEVEL_FIELDS = %w[name currency status account_type current_balance available_balance cash_balance reserved_balance balance_date sync_start_date metadata sensitive_details].freeze
  EVIDENCE_KEYS = %w[configuration connection_id external_accounts family_id frozen_context inventory observed_at profile provider_key version].freeze

  attr_reader :family, :external_records, :evidence, :context

  def self.fingerprint(value, purpose: "provider-runtime-inputs/v1")
    Fingerprint.new.call(value, purpose: purpose)
  end

  def initialize(connection, adapter:, observed_at:, sync: nil, evidence: nil)
    @connection, @adapter, @observed_at, @sync = connection, adapter, observed_at, sync
    @profile = validated_profile
    @evidence = evidence && Provider::AccountData::MigrationManifest.copy_value(evidence)
    validate_evidence! if evidence
  end

  def self.restore(connection, evidence)
    unless evidence.is_a?(Hash) && evidence["provider_key"] == connection.provider_key &&
        evidence["connection_id"] == connection.id && evidence["family_id"] == connection.family_id
      raise Provider::AccountData::StaleWriter, "Runtime input evidence belongs to another provider"
    end
    new(connection, adapter: Provider::AccountData::Registry.declared_adapter(connection.provider_key),
      observed_at: Time.iso8601(evidence.fetch("observed_at")), evidence: evidence)
  rescue KeyError, ArgumentError, TypeError
    raise Provider::AccountData::StaleWriter, "Runtime input evidence is invalid", cause: nil
  end

  # The caller already owns the connection lock. Lock the complete account union
  # before external/link rows, matching GenerationAccounts. Never extend a lock
  # plan after discovering that an AccountProvider changed in the meantime.
  def with_locks
    raise ArgumentError, "Runtime inputs require the connection transaction" if ProviderConnection.connection.open_transactions.zero?
    # Preference writes must wait; ordinary foreign-key checks need not wait.
    @family = Family.lock("FOR NO KEY UPDATE").find(connection.family_id)
    # Absent settings have defaults and may be inserted. Existing-row locks alone
    # cannot pin that choice. This short PostgreSQL table lock ends before HTTP;
    # at publication the outer transaction retains it through the financial write.
    Setting.connection.execute("LOCK TABLE #{Setting.connection.quote_table_name(Setting.table_name)} IN SHARE MODE")
    scope = connection.external_accounts.where(family_id: connection.family_id)
    if @profile["external_accounts"]
      sizes = scope.order(:id).limit(MAX_ACCOUNTS + 1).pluck(:id,
        Arel.sql("COALESCE(octet_length(metadata::text), 0) + COALESCE(octet_length(sensitive_details::text), 0)"))
      if sizes.size > MAX_ACCOUNTS || sizes.sum { |_, bytes| bytes.to_i } > MAX_STORED_BYTES
        raise Provider::AccountData::IncompletePage, "Runtime account inputs exceed their capture bound"
      end
      ids = sizes.map(&:first)
      planned = links_for(ids)
      account_ids = planned.values.map { |link| link.fetch("account_id") }.uniq.sort
      accounts = Account.where(family_id: connection.family_id, id: account_ids).order(:id).lock.index_by(&:id)
      unless accounts.keys == account_ids
        raise Provider::AccountData::StaleWriter, "Runtime account input ownership differs"
      end
      @external_records = scope.where(id: ids).order(:id).lock.to_a
      actual = links_for(ids, lock: true)
      unless external_records.size == ids.size && actual == planned
        raise Provider::AccountData::StaleWriter, "Runtime account linkage changed while acquiring locks"
      end
      links = AccountProvider.where(external_account_id: ids).index_by(&:external_account_id)
      external_records.each do |external|
        link = links[external.id]
        external.association(:account_provider).target = link
        external.association(:account).target = link && accounts.fetch(link.account_id)
      end
      identities = external_records.map(&:external_id)
      unless identities.all?(&:present?) && identities.uniq.size == identities.size
        # These adapters currently select cached context by upstream ID. Refuse
        # overlapping namespaces instead of letting find/to_h choose a sibling.
        raise Provider::AccountData::StaleWriter, "Runtime account IDs are ambiguous across namespaces"
      end
    else
      @external_records = []
    end
    Setting.uncached { yield }
  ensure
    @external_records = nil
  end

  def capture!(request_grant:)
    raise Provider::AccountData::StaleWriter, "Runtime inputs have already been captured" if evidence
    @context = Provider::AccountData::RuntimeContext.build(connection, adapter: adapter, observed_at: observed_at,
      sync: @sync, request_grant: request_grant, input_capture: self)
    rows = external_context
    @evidence = Provider::AccountData::MigrationManifest.copy_value(
      "version" => VERSION, "provider_key" => connection.provider_key, "connection_id" => connection.id,
      "family_id" => connection.family_id, "observed_at" => observed_at.utc.iso8601(9),
      "profile" => fingerprint(@profile), "configuration" => @live_fingerprint,
      "external_accounts" => rows.to_h { |row| [ row.fetch(:id), external_evidence(row) ] },
      "inventory" => inventory(rows),
      "frozen_context" => adapter.frozen_context_sources.to_h { |source| [ source.to_s, fingerprint(context.fetch(source)) ] }
        .merge("clock" => fingerprint(context.slice(:observed_at, :current_time))))
    verify!
    context
  end

  def record_live_inputs!(values)
    @live_fingerprint = fingerprint(values)
  end

  def verify!
    validate_evidence!
    live = Provider::AccountData::RuntimeContext.live_inputs(connection, adapter: adapter, family: family)
    unless fingerprint(live) == evidence.fetch("configuration")
      raise Provider::AccountData::StaleWriter, "Adapter configuration changed after construction"
    end
    current = external_context(include_frozen: false).index_by { |row| row.fetch(:id) }
    expected = evidence.fetch("external_accounts")
    unless (expected.keys - current.keys).empty? && inventory(current.values) == evidence.fetch("inventory")
      raise Provider::AccountData::StaleWriter, "Adapter account selection changed after construction"
    end
    expected.each do |id, captured|
      row = current.fetch(id)
      unless row.fetch(:identity_namespace) == captured.fetch("identity_namespace") &&
          fingerprint(project(row, BASE_FIELDS + external_paths("mutable"))) == captured.fetch("live")
        raise Provider::AccountData::StaleWriter, "Adapter account identity or routing changed after construction"
      end
    end
    true
  end

  def external_context(include_frozen: true)
    return [] unless @profile["external_accounts"]
    raise Provider::AccountData::StaleWriter, "Runtime input account locks are required" unless external_records
    Provider::AccountData::RuntimeContext.new(connection).external_accounts(records: external_records).map do |row|
      project(row, BASE_FIELDS + external_paths("mutable") + (include_frozen ? external_paths("frozen") : []))
    end
  end

  def inspect
    "#<#{self.class.name}>"
  end

  private
    attr_reader :connection, :adapter, :observed_at

    def validated_profile
      external = adapter.external_account_inputs&.deep_stringify_keys
      frozen = adapter.frozen_context_sources
      if (adapter.context_sources.include?(:external_accounts) || adapter.context_sources.include?(:simplefin_balance_classification)) && external.nil?
        raise ArgumentError, "Cached account context requires an input declaration"
      end
      if external
        unless external.keys.sort == %w[frozen inventory mutable] && %w[all linked].include?(external["inventory"])
          raise ArgumentError, "Invalid external account input declaration"
        end
        paths = external.values_at("mutable", "frozen")
        unless paths.all? { |items| items.is_a?(Array) } && paths.flatten.all? { |path| valid_path?(path) } &&
            paths.flatten.uniq.size == paths.flatten.size &&
            paths.flatten.combination(2).none? { |left, right| left.start_with?("#{right}.") || right.start_with?("#{left}.") }
          raise ArgumentError, "Invalid or duplicate external account input path"
        end
      end
      retained_sources = %i[sync_checkpoints known_merchant_names simplefin_balance_classification ibkr_export onchain_capture] +
        Provider::AccountData::RuntimeContext::RETAINED_SNAPSHOT_COLLECTORS.keys
      unless frozen.is_a?(Array) && frozen.uniq == frozen && (frozen - adapter.context_sources).empty? &&
          (frozen - retained_sources).empty?
        raise ArgumentError, "Invalid frozen runtime source declaration"
      end
      captured_sources = adapter.context_sources & retained_sources
      raise ArgumentError, "Retained runtime sources require a frozen declaration" unless (captured_sources - frozen).empty?
      { "external_accounts" => external, "frozen_sources" => frozen.map(&:to_s),
        "context_sources" => adapter.context_sources.map(&:to_s), "runtime_options" => adapter.runtime_options.map(&:to_s) }
    end

    def valid_path?(path)
      path.is_a?(String) && path.bytesize <= 128 && path.match?(/\A[a-z_]+(?:\.[a-z_]+){0,4}\z/) &&
        TOP_LEVEL_FIELDS.include?(path.split(".").first)
    end

    def external_paths(mode)
      @profile.dig("external_accounts", mode) || []
    end

    def inventory(rows)
      selected = @profile.dig("external_accounts", "inventory") == "all" ? rows : rows.select { |row| row[:linked_account] }
      selected.map { |row| row.fetch(:id) }.sort
    end

    def external_evidence(row)
      { "identity_namespace" => row.fetch(:identity_namespace),
        "live" => fingerprint(project(row, BASE_FIELDS + external_paths("mutable"))),
        "frozen" => fingerprint(project(row, external_paths("frozen"))) }
    end

    def project(row, paths)
      source = row.with_indifferent_access
      paths.each_with_object({}) do |path, result|
        keys = path.split(".")
        parent = keys[0...-1].inject(result) { |value, key| value[key.to_sym] ||= {} }
        value = keys.inject(source) { |item, key| item.is_a?(Hash) ? item.with_indifferent_access[key] : nil }
        parent[keys.last.to_sym] = value.deep_dup
      end
    end

    def links_for(ids, lock: false)
      query = AccountProvider.where(external_account_id: ids).order(:id)
      query = query.lock if lock
      query.to_h do |link|
        raise Provider::AccountData::StaleWriter, "Runtime linkage belongs to another family" unless link.family_id == connection.family_id
        [ link.external_account_id, link.slice("id", "account_id", "lock_version") ]
      end
    end

    def validate_evidence!
      unless evidence.is_a?(Hash) && evidence.keys.sort == EVIDENCE_KEYS && evidence["version"] == VERSION &&
          evidence["provider_key"] == connection.provider_key && evidence["connection_id"] == connection.id &&
          evidence["family_id"] == connection.family_id && evidence["observed_at"] == observed_at.utc.iso8601(9) &&
          evidence["profile"] == fingerprint(@profile) && valid_fingerprint?(evidence["configuration"]) &&
          evidence["external_accounts"].is_a?(Hash) && evidence["external_accounts"].size <= MAX_ACCOUNTS &&
          evidence["inventory"].is_a?(Array) && evidence["inventory"].size <= MAX_ACCOUNTS &&
          evidence["frozen_context"].is_a?(Hash) && evidence["frozen_context"].keys.sort == ([ "clock" ] + adapter.frozen_context_sources.map(&:to_s)).sort &&
          evidence["frozen_context"].values.all? { |value| valid_fingerprint?(value) }
        raise Provider::AccountData::StaleWriter, "Runtime input evidence or declaration changed"
      end
      evidence.fetch("external_accounts").each_value do |value|
        unless value.is_a?(Hash) && value.keys.sort == %w[frozen identity_namespace live] &&
            value["identity_namespace"].is_a?(String) && value["identity_namespace"].present? &&
            valid_fingerprint?(value["live"]) && valid_fingerprint?(value["frozen"])
          raise Provider::AccountData::StaleWriter, "Runtime account evidence is invalid"
        end
      end
    end

    def fingerprint(value)
      self.class.fingerprint(value)
    end

    def valid_fingerprint?(value)
      value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

  # Separate instances keep structural counters local to one fingerprint. Both
  # factory and per-request inputs use the same typed, bounded representation.
  class Fingerprint
    def call(value, purpose:)
      @nodes = 0
      encoded = JSON.generate(encode(value))
      raise Provider::AccountData::IncompletePage, "Runtime input exceeds its byte bound" if encoded.bytesize > MAX_INPUT_BYTES
      key = Rails.application.key_generator.generate_key(purpose, 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, encoded)
    end

    private
      def encode(value, depth = 0)
        @nodes += 1
        if depth > 32 || @nodes > MAX_NODES
          raise Provider::AccountData::IncompletePage, "Runtime input exceeds its structural bound"
        end
        case value
        when Hash
          pairs = value.map { |key, item| [ encode(key, depth + 1), encode(item, depth + 1) ] }
          [ "hash", pairs.sort_by { |key, _| JSON.generate(key) } ]
        when Array then [ "array", value.map { |item| encode(item, depth + 1) } ]
        when Regexp then [ "regexp", [ value.source, value.options ] ]
        else Provider::AccountData::MigrationValue.encode(value)
        end
      end
  end
  private_constant :Fingerprint
end
