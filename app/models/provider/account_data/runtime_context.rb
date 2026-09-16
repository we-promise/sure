# Resolve deployment settings once at the application boundary. The adapter's
# factory receives explicit values and stays independent of Rails/ENV/database
# lookups. Never include credentials or copy this context into public metadata.
class Provider::AccountData::RuntimeContext
  SOURCES = %i[connection_details authorizations external_accounts sync_checkpoints known_merchant_names binance_history_seed].freeze
  # Only reviewed application classes may supply feature-specific snapshots.
  # Neither connection metadata nor provider keys can resolve an arbitrary class.
  SNAPSHOT_COLLECTORS = {
    simplefin_balance_classification: "Ingestion::BalancePolicies::Simplefin::Snapshot"
  }.freeze
  SYNC_SNAPSHOT_COLLECTORS = {
    ibkr_export: "Provider::AccountData::Ibkr::Archive",
    onchain_capture: "Provider::AccountData::OnchainWallet::CaptureArchive"
  }.freeze
  RETAINED_SNAPSHOT_COLLECTORS = {
    trading212_instrument_catalog: "Provider::AccountData::Trading212::InstrumentCatalog",
    wise_account_history: "Provider::AccountData::Wise::AccountHistory",
    monobank_retained_history: "Provider::AccountData::Monobank::RetainedHistory",
    trade_republic_retained_portfolio: "Provider::AccountData::TradeRepublic::RetainedPortfolio",
    questrade_retained_credentials: "Provider::AccountData::Questrade::RetainedCredentials",
    plaid_deployment_binding: "Provider::AccountData::Plaid::DeploymentBinding"
  }.freeze
  RUNTIME_DEPENDENCIES = %i[credential_store nonce_generator exchange_rate_resolver application_credentials fallback_credentials onchain_configuration onchain_fx_credentials].freeze

  def self.live_inputs(connection, adapter:, family: connection.family.reload)
    configuration = Rails.configuration.x[adapter.definition.key] || {}
    options = adapter.runtime_options.to_h do |key|
      raise ArgumentError, "Runtime option names must be symbols" unless key.is_a?(Symbol)
      [ key, configuration[key] ]
    end.compact
    requested = adapter.context_sources
    unless requested.is_a?(Array) && (requested - SOURCES - SNAPSHOT_COLLECTORS.keys - SYNC_SNAPSHOT_COLLECTORS.keys - RETAINED_SNAPSHOT_COLLECTORS.keys - RUNTIME_DEPENDENCIES).empty? && requested.uniq == requested
      raise ArgumentError, "Unknown or duplicate runtime context source"
    end
    context = {
      timezone: family.timezone, family_currency: family.currency, family_locale: family.locale, region: connection.region,
      environment: connection.environment,
      configured_options: options.deep_dup,
      pending_preference: pending_preference,
      pending_override: ENV["#{adapter.definition.key.upcase}_INCLUDE_PENDING"].present?
    }
    resolver = new(connection)
    context[:connection_details] = resolver.connection_details if requested.include?(:connection_details)
    if requested.include?(:binance_history_seed)
      context[:binance_history_seed] = Provider::AccountData::Binance::HistoryBootstrap.runtime_input(connection)
    end
    context[:application_credentials] = Provider::AccountData::ApplicationCredentials.build(connection) if requested.include?(:application_credentials)
    context[:fallback_credentials] = Provider::AccountData::ApplicationCredentials.fallback(connection) if requested.include?(:fallback_credentials)
    context[:onchain_configuration] = Provider::AccountData::OnchainWallet::Configuration.build if requested.include?(:onchain_configuration)
    context[:onchain_fx_credentials] = Provider::AccountData::OnchainWallet::FxConfiguration.credentials if requested.include?(:onchain_fx_credentials)
    policy = if requested.include?(:simplefin_balance_classification)
      Ingestion::BalancePolicies::Simplefin::Snapshot.configuration
    end
    live = { settings: connection.settings.deep_dup, context: context, simplefin_policy: policy }
    if requested.include?(:simplefin_balance_classification)
      live[:simplefin_retained_hints] = Provider::AccountData::Simplefin::RetainedHint.live_input(connection: connection)
    end
    retained_sources = requested & RETAINED_SNAPSHOT_COLLECTORS.keys
    if retained_sources.any?
      live[:retained_sources] = retained_sources.to_h do |source|
        [ source, RETAINED_SNAPSHOT_COLLECTORS.fetch(source).constantize.live_input(connection: connection) ]
      end
    end
    live
  end

  # Use the same field coercion and default semantics as rails-settings-cached,
  # without its request/shared cache. Another worker cannot clear this worker's
  # RequestCache, so a regular Setting getter cannot authorize publication.
  def self.pending_preference
    field = Setting.defined_fields.find { |definition| definition.key == "syncs_include_pending" }
    raise ArgumentError, "Pending preference has no declared field" unless field
    Setting.uncached do
      stored = Setting.unscoped.find_by(var: field.key)&.value
      field.deserialize(field.readonly || stored.nil? ? field.default_value : stored)
    end
  end

  def self.build(connection, adapter:, observed_at:, sync: nil, request_grant: nil, input_capture: nil)
    live = live_inputs(connection, adapter: adapter, family: input_capture ? input_capture.family : connection.family.reload)
    input_capture&.record_live_inputs!(live)
    context = live.fetch(:context).merge(observed_at: observed_at, current_time: Time.current)
    resolver = new(connection)
    adapter.context_sources.each do |source|
      next if context.key?(source)
      context[source] = if source == :credential_store
        Provider::AccountData::CredentialStore.new(connection: connection, request_grant: request_grant)
      elsif source == :nonce_generator
        Provider::AccountData::NonceGenerator.new(connection: connection)
      elsif source == :exchange_rate_resolver
        Provider::AccountData::ExchangeRateResolver.new
      elsif source == :external_accounts && input_capture
        input_capture.external_context
      elsif source == :simplefin_balance_classification
        { version: 2, accounts: Ingestion::BalancePolicies::Simplefin::Snapshot.build(connection: connection, observed_at: observed_at,
          external_accounts: input_capture&.external_records, configuration: live.fetch(:simplefin_policy), key_by: :id) }
      elsif SNAPSHOT_COLLECTORS.key?(source)
        SNAPSHOT_COLLECTORS.fetch(source).constantize.build(connection: connection, observed_at: observed_at)
      elsif RETAINED_SNAPSHOT_COLLECTORS.key?(source)
        RETAINED_SNAPSHOT_COLLECTORS.fetch(source).constantize.build(connection: connection, observed_at: observed_at,
          external_accounts: input_capture&.external_records)
      elsif SYNC_SNAPSHOT_COLLECTORS.key?(source)
        SYNC_SNAPSHOT_COLLECTORS.fetch(source).constantize.build(connection: connection, sync: sync, observed_at: observed_at)
      else
        resolver.public_send(source)
      end
    end
    context.deep_dup
  end

  def initialize(connection)
    @connection = connection
  end

  def connection_details
    { id: connection.id, family_id: connection.family_id, external_id: connection.external_id,
      sync_start_date: connection.sync_start_date&.iso8601, settings: connection.settings, metadata: connection.metadata }
  end

  def authorizations
    connection.provider_authorizations.where(family_id: connection.family_id).order(:id).map do |authorization|
      {
        id: authorization.id, external_id: authorization.external_id, status: authorization.status,
        expires_at: authorization.expires_at&.iso8601(9), credentials: authorization.credentials,
        institution_metadata: authorization.institution_metadata, metadata: authorization.metadata
      }
    end
  end

  def external_accounts(records: nil)
    rows = records || connection.external_accounts.where(family_id: connection.family_id)
      .includes(:account, :provider_authorization_accounts).order(:id)
    rows.map do |external|
      linked = external.current_account
      if linked && linked.family_id != connection.family_id
        raise Provider::AccountData::InvalidResponse, "Linked account belongs to another family"
      end
      memberships = external.provider_authorization_accounts.select do |membership|
        membership.active? && membership.family_id == connection.family_id && membership.provider_connection_id == connection.id
      end
      {
        id: external.id, external_id: external.external_id, identity_namespace: external.identity_namespace,
        name: external.name, currency: external.currency, status: external.status, account_type: external.account_type,
        current_balance: external.current_balance, available_balance: external.available_balance,
        cash_balance: external.cash_balance, reserved_balance: external.reserved_balance, balance_date: external.balance_date&.iso8601,
        sync_start_date: external.sync_start_date&.iso8601,
        metadata: external.metadata, sensitive_details: external.sensitive_details,
        authorization_ids: memberships.map(&:provider_authorization_id).sort,
        linked_account: linked && { id: linked.id, currency: linked.currency, accountable_type: linked.accountable_type,
          accountable_id: linked.accountable_id, account_provider_id: external.account_provider.id,
          account_provider_revision: external.account_provider.lock_version }
      }
    end
  end

  def sync_checkpoints
    connection.provider_sync_checkpoints.where(family_id: connection.family_id).order(:id).map do |checkpoint|
      {
        external_account_id: checkpoint.external_account_id, authorization_id: checkpoint.provider_authorization_id,
        stream: checkpoint.stream, scope_key: checkpoint.scope_key, cursor: checkpoint.cursor,
        state: checkpoint.state, covered_through: checkpoint.covered_through&.iso8601(9)
      }
    end
  end

  def known_merchant_names
    connection.family.known_merchant_names
  end

  private
    attr_reader :connection
end
