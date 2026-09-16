require "bigdecimal"
require "digest"

# Links discovered identities through one shared, authorized command. A second
# source keeps existing policies; switching authority is a separate operation.
class ProviderConnection::AccountSetup
  class Conflict < Provider::AccountData::StaleWriter; end
  class Busy < Provider::AccountData::IncompletePage; end
  Catalog = Data.define(:connection, :external_accounts, :existing_accounts, :account_types, :next_cursor)
  Form = Data.define(:connection, :external_account, :account, :token, :account_types, :secondary)
  Result = Data.define(:account, :account_provider, :sync)
  PURPOSE = "provider-account-setup/v1".freeze
  MAX_TOKEN_BYTES = 8.kilobytes
  PAGE_SIZE = 50
  MAX_TARGETS = 200
  MAX_LINKS = 32

  def initialize(connection:, actor:)
    @management = ProviderConnection::Management.new(connection: connection, actor: actor)
  end

  def catalog(after: nil)
    raise ArgumentError, "Invalid account page" unless after.nil? || uuid?(after)
    with_context do
      scope = connection.external_accounts.active.unlinked.order(:id)
      scope = scope.where("external_accounts.id > ?", after) if after
      rows = scope.limit(PAGE_SIZE + 1).to_a
      targets = Account.where(family_id: connection.family_id).visible.writable_by(actor)
        .where(accountable_type: types).includes(:account_providers).order(:name, :id).limit(MAX_TARGETS).to_a
      targets.select! do |account|
        next false if account.plaid_account_id || account.simplefin_account_id
        links = account.account_providers.to_a
        links.size < MAX_LINKS && links.all? { |link| link.external_account_id && link.provider_key != connection.provider_key }
      end
      Catalog.new(connection: connection, external_accounts: rows.first(PAGE_SIZE), existing_accounts: targets,
        account_types: types, next_cursor: rows.size > PAGE_SIZE ? rows[PAGE_SIZE - 1].id : nil)
    end
  end

  def form(external_account_id:, account_id: nil)
    with_context do
      idle_connection!
      account = account_id && load_account!(account_id)
      external = load_external!(external_account_id)
      validate_unlinked!(external)
      target = target_context!(account, external)
      selection = selection_binding(external, account, target)
      token = verifier.generate({ "command_id" => SecureRandom.uuid, "binding" => selection }, purpose: PURPOSE, expires_in: 30.minutes)
      Form.new(connection: connection, external_account: external, account: account, token: token,
        account_types: types, secondary: target.fetch("links").any?)
    end
  end

  def apply!(token:, attributes:)
    # The durable receipt and job handoff must belong to this command's commit.
    raise ArgumentError, "Account setup must start outside a database transaction" if ApplicationRecord.connection.transaction_open?
    expected = verify_token!(token)
    result = with_context do
      binding = expected.fetch("binding")
      refuse! unless binding.dig("management", "connection_id") == connection.id &&
        binding.dig("management", "actor_id") == actor.id && binding.dig("management", "family_id") == connection.family_id
      values = validate_attributes!(attributes, creating: binding["account_id"].nil?)
      previous = connection.syncs.lock("FOR UPDATE NOWAIT").find_by(id: expected.fetch("command_id"))
      if previous
        replay!(previous, token, values)
      else
        idle_connection!
        account = binding["account_id"] && load_account!(binding.fetch("account_id"))
        external = load_external!(binding.fetch("external_account_id"))
        validate_unlinked!(external)
        target = target_context!(account, external)
        refuse! unless binding == selection_binding(external, account, target)
        if account.nil?
          unless external.currency.blank? || values.fetch("currency") == external.currency
            raise ArgumentError, "Account currency must match the discovered source"
          end
          defaults = account_creation_defaults!(external, values.fetch("accountable_type"))
          account = Account.create_and_sync(values.symbolize_keys.merge(defaults).merge(family: connection.family, owner: actor), skip_initial_sync: true)
        end
        link = AccountProvider.create!(account: account, external_account: external)
        if target.fetch("links").empty?
          Account::SourcePolicy.select_many!(account: account, account_provider: link, resources: resources)
        end
        sync = connection.syncs.create!(id: expected.fetch("command_id"))
        external.reload
        Provider::AccountData::RetainedTransactions.new(external_account: external, sync: sync).call if resources.include?("transactions")
        sync.update!(data: (sync.data || {}).merge("account_setup" => receipt(token, values, account, link)))
        connection.update!(pending_account_setup: connection.external_accounts.active.unlinked.exists?)
        Result.new(account: account, account_provider: link, sync: sync)
      end
    end
    dispatch(result.sync)
    result
  end

  def refresh!
    raise ArgumentError, "Discovery must start outside a database transaction" if ApplicationRecord.connection.transaction_open?
    sync = with_context do
      idle_connection!(allow_pending: true)
      existing = connection.syncs.incomplete.lock("FOR UPDATE NOWAIT").to_a
      if existing.empty?
        connection.syncs.create!
      elsif existing.one? && existing.first.pending? && existing.first.cancel_requested_at.nil?
        existing.first
      else
        raise Busy, "Finish provider work before refreshing discovered accounts"
      end
    end
    dispatch(sync)
    sync
  end

  private
    attr_reader :connection, :actor, :types, :resources, :adapter

    def with_context
      @management.with_lock do |context|
        @context, @connection, @actor = context, context.connection, context.actor
        @adapter = Provider::AccountData::Registry.fetch(connection.provider_key)
        @types, @resources = adapter.account_setup_types, adapter.account_setup_resources
        unless types.is_a?(Array) && types.any? && types.uniq == types && (types - Accountable::TYPES).empty? &&
            resources.is_a?(Array) && resources.uniq == resources && resources.include?("balances") &&
            (resources - Account::SourcePolicy::RESOURCES).empty?
          raise Provider::AccountData::UnsupportedCapability, "Provider account setup is not ready"
        end
        refuse! unless connection.good?
        yield
      end
    rescue Provider::AccountData::IncompletePage, ActiveRecord::LockWaitTimeout
      raise Busy, "Account setup encountered active work; retry after it finishes", cause: nil
    rescue Provider::AccountData::StaleWriter, Provider::AccountData::InvalidResponse,
        ActiveRecord::RecordNotFound, ActiveRecord::StaleObjectError, Provider::AccountData::MigrationCopier::Conflict
      refuse!
    end

    def idle_connection!(source: connection, allow_pending: false)
      if source.lease_owner || source.lease_expires_at || source.lease_sync_id ||
          source.provider_sync_generations.unfinished.exists? || (!allow_pending && source.syncs.incomplete.exists?)
        raise Busy, "Finish provider work before setting up accounts"
      end
    end

    def load_account!(id)
      refuse! unless uuid?(id)
      account = Account.where(id: id, family_id: connection.family_id).visible.lock("FOR UPDATE NOWAIT").first!
      share = account.account_shares.where(user_id: actor.id).lock("FOR UPDATE NOWAIT").first
      refuse! unless account.owner_id == actor.id || share&.permission == "full_control"
      raise Busy, "Finish financial account work before linking a source" if account.syncs.incomplete.exists?
      account
    end

    def load_external!(id)
      refuse! unless uuid?(id)
      connection.external_accounts.where(id: id, family_id: connection.family_id, provider_key: connection.provider_key)
        .lock("FOR UPDATE NOWAIT").first!
    end

    def validate_unlinked!(external)
      refuse! unless external.active? && external.external_id.present? && external.identity_namespace == "connection" &&
        !AccountProvider.where(external_account_id: external.id).exists?
      observations = SourceRecord.where(external_account_id: external.id)
      if observations.where.not(kind: "transaction").exists?
        raise Conflict, "Retained investment observations require their own setup replay contract"
      end
      if observations.where.not(account_id: nil).exists? || EntrySource.where(source_record_id: observations.select(:id)).exists? ||
          HoldingSource.where(source_record_id: observations.select(:id)).exists? ||
          Account::SourcePolicy.where("source_binding ->> 'external_account_id' = ?", external.id).exists?
        raise Conflict, "This source has financial history and requires an explicit relinking decision"
      end
      validate_retained_source!(external)
    end

    def validate_retained_source!(external)
      retained = Provider::AccountData::RetainedRow.new(connection: connection, provider_key: connection.provider_key).account(external)
      return unless retained
      # These reviewed account-scoped ports require an empty never-linked cache
      # at cutover. A new link cannot rewrite the archive's original nil binding.
      unless %w[up mercury brex akahu].include?(connection.provider_key)
        raise Conflict, "This provider needs a retained-history setup contract"
      end
      Provider::AccountData::MigrationCopier.verify_account_binding!(archive: retained.archive, link: nil, financial: nil)
      raw = retained.attributes.fetch("raw_transactions_payload")
      refuse! unless raw.nil? || raw == []
      context = retained.context
      if AccountProvider.where(provider_type: context.fetch("legacy_type"), provider_id: context.fetch("legacy_id")).exists?
        refuse!
      end
    rescue Provider::AccountData::StaleWriter, Provider::AccountData::MigrationCopier::Conflict, KeyError
      refuse!
    end

    def target_context!(account, external)
      return { "links" => [], "policies" => [] } unless account
      refuse! unless types.include?(account.accountable_type) && (external.currency.blank? || external.currency == account.currency)
      refuse! if account.plaid_account_id || account.simplefin_account_id
      links = account.account_providers.order(:id).limit(MAX_LINKS + 1).lock("FOR UPDATE NOWAIT").to_a
      refuse! if links.size >= MAX_LINKS
      links.each do |link|
        refuse! unless link.external_account_id && link.family_id == account.family_id && link.provider_key != connection.provider_key
        source = ExternalAccount.where(id: link.external_account_id, family_id: account.family_id).lock("FOR UPDATE NOWAIT").first!
        refuse! unless source.provider_key == link.provider_key && source.active?
        ProviderConnection::Management.new(connection: source.provider_connection, actor: actor).with_lock do |other|
          idle_connection!(source: other.connection)
        end
      end
      policies = Account::SourcePolicy.active.where(account: account).order(:resource).lock("FOR UPDATE NOWAIT").to_a
      if links.empty?
        refuse! if policies.any?
      else
        refuse! unless (resources - policies.map(&:resource)).empty?
        policies.each do |policy|
          refuse! unless links.any? { |link| link.id == policy.account_provider_id }
          Account::SourcePolicy::Binding.verify_live!(policy: policy)
        end
      end
      { "links" => links.map { |link| link.attributes.slice("id", "account_id", "family_id", "provider_type", "provider_id", "provider_key", "external_account_id", "lock_version") },
        "policies" => policies.map { |policy| policy.attributes.slice("id", "account_provider_id", "resource", "revision", "source_binding") } }
    end

    def selection_binding(external, account, target)
      { "management" => @context.binding, "external_account_id" => external.id, "account_id" => account&.id,
        "external_fingerprint" => fingerprint(external.attributes.except("sensitive_details")),
        "account_fingerprint" => account && fingerprint(account.attributes), "target_fingerprint" => fingerprint(target),
        "types" => types, "resources" => resources,
        "setup_defaults" => types.to_h { |type| [ type, account_defaults!(external, type) ] } }
    end

    def validate_attributes!(attributes, creating:)
      raise ArgumentError, "Account values must be an object" unless attributes.is_a?(Hash)
      values = attributes.stringify_keys
      unless creating
        raise ArgumentError, "Existing account values cannot change during setup" unless values.empty?
        return values
      end
      unless values.keys.sort == %w[accountable_type balance currency name] &&
          values["name"].is_a?(String) && values["name"].present? && values["name"].bytesize <= 255 &&
          types.include?(values["accountable_type"]) && values["currency"].is_a?(String) &&
          values["currency"].match?(/\A[A-Z]{3}\z/) && values["balance"].is_a?(String) &&
          values["balance"].match?(/\A-?\d{1,15}(?:\.\d{1,4})?\z/)
        raise ArgumentError, "Supply a name, supported type, currency and explicit decimal balance"
      end
      Money::Currency.new(values.fetch("currency"))
      values.merge("balance" => BigDecimal(values.fetch("balance")))
    rescue Money::Currency::UnknownCurrencyError
      raise ArgumentError, "Account currency is not supported", cause: nil
    end

    def account_defaults!(external, accountable_type)
      input = Provider::AccountData::MigrationManifest.copy_value(
        { "account_type" => external.account_type, "currency" => external.currency, "metadata" => external.metadata })
      defaults = adapter.account_setup_defaults(account: input, accountable_type: accountable_type.dup.freeze)
      valid = defaults.is_a?(Hash) && (defaults.keys - %w[subtype cash_balance]).empty?
      if valid && defaults.key?("subtype")
        klass = accountable_type.constantize # Already restricted to Accountable::TYPES.
        valid = defaults["subtype"].is_a?(String) && klass.const_defined?(:SUBTYPES) && klass::SUBTYPES.key?(defaults["subtype"])
      end
      if valid && defaults.key?("cash_balance")
        valid = defaults["cash_balance"].is_a?(String) && defaults["cash_balance"].match?(/\A-?\d{1,15}(?:\.\d{1,4})?\z/)
      end
      raise Provider::AccountData::UnsupportedCapability, "Provider account setup defaults are invalid" unless valid

      Provider::AccountData::MigrationManifest.copy_value(defaults)
    end

    def account_creation_defaults!(external, accountable_type)
      defaults = account_defaults!(external, accountable_type)
      {}.tap do |attributes|
        attributes[:accountable_attributes] = { subtype: defaults.fetch("subtype") } if defaults.key?("subtype")
        attributes[:cash_balance] = BigDecimal(defaults.fetch("cash_balance")) if defaults.key?("cash_balance")
      end
    end

    def receipt(token, values, account, link)
      { "format" => PURPOSE, "token_digest" => Digest::SHA256.hexdigest(token), "values_digest" => fingerprint(values),
        "actor_id" => actor.id, "external_account_id" => link.external_account_id, "account_id" => account.id,
        "account_provider_id" => link.id, "policy_ids" => policy_ids(account),
        "account_context" => account.attributes.slice("family_id", "currency", "accountable_type", "accountable_id") }
    end

    def replay!(sync, token, values)
      saved = sync.data&.fetch("account_setup", nil)
      refuse! unless saved.is_a?(Hash) && saved["format"] == PURPOSE && saved["actor_id"] == actor.id &&
        saved["token_digest"] == Digest::SHA256.hexdigest(token) && saved["values_digest"] == fingerprint(values)
      account = load_account!(saved.fetch("account_id"))
      external = load_external!(saved.fetch("external_account_id"))
      link = AccountProvider.where(id: saved.fetch("account_provider_id"), external_account_id: external.id,
        account_id: account.id, family_id: connection.family_id, provider_key: connection.provider_key).lock("FOR UPDATE NOWAIT").first!
      refuse! unless external.active? && saved["policy_ids"] == policy_ids(account) &&
        saved["account_context"] == account.attributes.slice("family_id", "currency", "accountable_type", "accountable_id") && sync.cancel_requested_at.nil?
      Result.new(account: account, account_provider: link, sync: sync)
    end

    def policy_ids(account)
      Account::SourcePolicy.active.where(account: account).order(:resource).pluck(:resource, :id).to_h
    end

    def verify_token!(token)
      refuse! unless token.is_a?(String) && token.bytesize <= MAX_TOKEN_BYTES
      value = verifier.verified(token, purpose: PURPOSE)
      refuse! unless value.is_a?(Hash) && uuid?(value["command_id"]) && value["binding"].is_a?(Hash)
      value
    end

    def dispatch(sync)
      return unless sync.pending? && sync.cancel_requested_at.nil?
      if sync.resume_at && sync.resume_at > Time.current
        SyncJob.set(wait_until: sync.resume_at).perform_later(sync)
      else
        SyncJob.perform_later(sync)
      end
    end

    def fingerprint(value)
      Digest::SHA256.hexdigest(Provider::AccountData::MigrationValue.dump(value))
    end

    def uuid?(value)
      value.is_a?(String) && value.match?(Provider::AccountData::LegacyWriterFence::UUID)
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def refuse!
      raise Conflict, "Account setup ownership or selection changed; reload before continuing", cause: nil
    end
end
