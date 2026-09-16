# An injected client owns HTTP, authentication, pagination and provider errors.
# Adapters normalize responses without writes to the database or job scheduling.
class Provider::AccountData::Adapter
  def self.definition
    raise Provider::AccountData::NotImplementedError, "Declare the integration definition"
  end

  def self.build(credentials:, settings:, context:)
    raise Provider::AccountData::NotImplementedError, "Implement the integration client factory"
  end

  # A port opts in only after all of its required shared runtime capabilities
  # exist. Discovery alone must not activate a partially implemented integration.
  def self.native_ready?
    false
  end

  # Explicitly reviewed static credentials that an administrator may replace.
  # Rotating sessions, application credentials and grants need their own flow.
  def self.editable_connection_credentials
    []
  end

  # Account setup opts in separately from discovery and native sync. Historical
  # caches and financial identity must support a newly linked account first.
  def self.account_setup_types
    []
  end

  def self.account_setup_resources
    [ "balances", *definition.capabilities ]
  end

  # Pure defaults for a NEW financial account. The runtime passes deeply frozen
  # nonsecret source data and validates only subtype and decimal cash_balance.
  # The explicitly entered balance, name, currency and owner cannot be replaced.
  def self.account_setup_defaults(account:, accountable_type:)
    {}
  end

  # Nonsecret deployment options required by this integration. RuntimeContext
  # copies only these keys from config.x; factories never read global state.
  def self.runtime_options
    []
  end

  # Named, family-scoped domain snapshots resolved once by RuntimeContext. An
  # integration never queries application models from its pure factory/reader.
  def self.context_sources
    []
  end

  # Paths explicitly exposed from retained ExternalAccount context. Identity,
  # namespace and linked account identity/type/currency are always live inputs.
  # Frozen paths describe a baseline for this execution, not current authority.
  def self.external_account_inputs
    nil
  end

  def self.frozen_context_sources
    []
  end

  def initialize(client:)
    @client = client
  end

  attr_reader :request_grant

  def bind_request_grant!(grant)
    raise Provider::AccountData::StaleWriter, "Adapter already owns a request grant" if @request_grant
    @request_grant = grant
    self
  end

  def capabilities
    self.class.definition.capabilities
  end

  def transaction_scope
    :account
  end

  def activity_scope
    :account
  end

  # Partial fetch progress normally survives into a later sync. Snapshot-bound
  # cursors opt into :sync: attempts of that Sync resume, but a new Sync starts
  # from the completed checkpoint without adopting the old snapshot's offset.
  # This does not change the lifetime of a completed checkpoint cursor.
  def progress_cursor_scope(stream:)
    :connection
  end

  # Only an adapter with replayable, captured topic/detail state may resume a
  # partially fetched connection generation in the same logical Sync.
  def resumable_activity_groups?
    false
  end

  # Only explicitly classified transport failures may defer a captured activity
  # request. Attempt counts belong to its generation, not pagination scheduling.
  # Return bounded seconds or nil; the runtime owns validation and scheduling.
  def activity_group_retry_delay(error:, attempt:)
    nil
  end

  # Pure initial transaction-history policy. The runtime supplies its captured
  # clock and only the declared account metadata; nil requests unbounded history.
  # Explicit dates and completed checkpoints take precedence in the syncer.
  def initial_history_start(account:, observed_at:)
    observed_at - 90.days
  end

  def checkpoint_history_start(account:, observed_at:, covered_through:)
    covered_through - 7.days
  end

  # A provider may limit initial backfills, including explicit user windows.
  # This is a lower bound only; it must not move the requested end forward.
  def initial_history_floor(account:, observed_at:)
    nil
  end

  def self.initial_history_metadata_keys
    []
  end

  # Opt in only when a provider's stable transaction ID cannot revert from
  # posted to pending. The writer still resolves its exact financial proof first.
  def self.transaction_status_policy
    nil
  end

  # A successful complete account inventory is required before pruning is possible.
  # Return Page, with explicit completeness; partial inventories never imply removal.
  def list_accounts(cursor: nil)
    raise Provider::AccountData::NotImplementedError, "Implement account normalization"
  end

  def fetch_transactions(account:, cursor: nil, window: nil)
    require_capability!("transactions")
    raise Provider::AccountData::NotImplementedError, "Implement transaction normalization"
  end

  def fetch_balance(account:, cursor: nil, window: nil)
    raise Provider::AccountData::InvalidResponse, "Account balance has no continuation" unless cursor.nil?
    metadata = account[:metadata] || {}
    if metadata.fetch(:balance_snapshot_current) { metadata["balance_snapshot_current"] } == false
      raise Provider::AccountData::IncompletePage, "The current inventory did not include this account's balance"
    end
    Provider::AccountData::Page.new(records: [ account ], complete: true, mode: "snapshot")
  end

  def fetch_holdings(account:, cursor: nil, window: nil)
    require_capability!("holdings")
    raise Provider::AccountData::NotImplementedError, "Implement holdings normalization"
  end

  def fetch_activities(account:, cursor: nil, window: nil)
    require_capability!("activities")
    raise Provider::AccountData::NotImplementedError, "Implement investment activity normalization"
  end

  # Inspecting an adapter must not expose the injected client's credentials.
  def inspect
    "#<#{self.class.name}>"
  end

  private
    attr_reader :client

    def require_capability!(capability)
      unless self.class.definition.supports?(capability)
        raise Provider::AccountData::UnsupportedCapability, "#{self.class.definition.key} does not support #{capability}"
      end
    end
end
