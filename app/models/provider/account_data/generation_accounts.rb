# Captures publication bindings before network I/O and checks them again under
# ordered account locks. A sealed generation cannot silently adopt a new link, grant,
# visibility choice or source-policy revision when a later worker resumes it.
class Provider::AccountData::GenerationAccounts
  MAX_ACCOUNTS = 10_000

  def initialize(connection, resource: "transactions", identity_namespace: "connection")
    raise ArgumentError, "Unknown publication resource" unless %w[transactions balances holdings activities].include?(resource)
    raise ArgumentError, "Account identity namespace is required" unless identity_namespace.is_a?(String) && identity_namespace.present?
    @connection = connection
    @resource = resource
    @identity_namespace = identity_namespace
  end

  def capture_one(external)
    unless external.provider_connection_id == connection.id && external.family_id == connection.family_id && external.identity_namespace == identity_namespace
      raise Provider::AccountData::StaleWriter, "Publication account belongs to another connection"
    end
    with_lock_plan([ external ]) { |locked| snapshot(locked.sole) }
  end

  def capture
    accounts = connection.external_accounts.where(identity_namespace: identity_namespace).order(:id).limit(MAX_ACCOUNTS + 1).to_a
    raise Provider::AccountData::IncompletePage, "Connection inventory exceeds its capture limit" if accounts.size > MAX_ACCOUNTS
    with_lock_plan(accounts) do |locked|
      locked.to_h do |external|
        raise Provider::AccountData::InvalidResponse, "Account identity is unresolved" if external.external_id.blank?
        binding = snapshot(external)
        if resource == "transactions" && binding["publication"] == "ledger" && external.transaction_backfill_required?
          raise Provider::AccountData::IncompletePage, "Linked account requires replay of retained transaction history"
        end
        [ external.external_id, binding ]
      end
    end
  end

  def with_verified_binding(external, expected)
    unless expected.is_a?(Hash) && external.provider_connection_id == connection.id && external.family_id == connection.family_id &&
        expected["external_account_id"] == external.id
      raise Provider::AccountData::StaleWriter, "Generation account belongs to another connection"
    end
    with_verified_bindings(external.external_id => expected) do |locked|
      yield locked.fetch(external.external_id)
    end
  end

  def with_verified_bindings(expected)
    unless expected.is_a?(Hash) && expected.size <= MAX_ACCOUNTS && expected.values.all? { |binding| binding.is_a?(Hash) && binding["external_account_id"].present? }
      raise Provider::AccountData::StaleWriter, "Generation account bindings are invalid"
    end
    ids = expected.values.map { |binding| binding.fetch("external_account_id") }
    externals = connection.external_accounts.where(family_id: connection.family_id, identity_namespace: identity_namespace, id: ids).order(:id).to_a
    unless ids.uniq.size == ids.size && externals.size == ids.size &&
        externals.all? { |external| expected[external.external_id]&.fetch("external_account_id") == external.id }
      raise Provider::AccountData::StaleWriter, "Generation account belongs to another connection"
    end
    with_lock_plan(externals, expected: expected) do |locked|
      locked.each do |external|
        unless snapshot(external) == expected.fetch(external.external_id)
          raise Provider::AccountData::StaleWriter, "Generation account binding changed after capture"
        end
      end
      yield locked.index_by(&:external_id)
    end
  end

  private
    attr_reader :connection, :resource, :identity_namespace

    def with_lock_plan(externals, expected: nil)
      ExternalAccount.transaction do
        ids = externals.map(&:id)
        planned_links = links_for(ids)
        if expected
          externals.each do |external|
            binding = expected.fetch(external.external_id)
            link = planned_links[external.id]
            unless link&.fetch(:id) == binding["account_provider_id"] && link&.fetch(:account_id) == binding["account_id"] &&
                link&.fetch(:lock_version) == binding["account_provider_revision"]
              raise Provider::AccountData::StaleWriter, "Generation account link changed before acquiring its lock"
            end
          end
        end

        # Different providers can link the same financial accounts in opposite
        # inventory orders. Lock their complete union in the common UUID order
        # before taking any source/link locks. Never extend this plan on a race.
        account_ids = planned_links.values.map { |link| link.fetch(:account_id) }.uniq.sort
        lock_accounts(account_ids)
        locked = connection.external_accounts.where(family_id: connection.family_id, id: ids).order(:id).lock.to_a
        actual_links = links_for(ids, lock: true)
        unless locked.size == ids.size && actual_links == planned_links
          raise Provider::AccountData::StaleWriter, "Generation account link changed while acquiring its lock"
        end
        # External FOR UPDATE also blocks new link/membership insertions through
        # their foreign keys. Existing link rows are now locked and rechecked.
        yield locked
      end
    end

    def links_for(external_ids, lock: false)
      links = AccountProvider.where(external_account_id: external_ids).order(:id)
      links = links.lock if lock
      links.to_h do |link|
        unless link.family_id == connection.family_id
          raise Provider::AccountData::StaleWriter, "Generation account linkage has inconsistent ownership"
        end
        [ link.external_account_id, { id: link.id, account_id: link.account_id, lock_version: link.lock_version } ]
      end
    end

    def lock_accounts(ids)
      locked = Account.where(family_id: connection.family_id, id: ids).order(:id).lock.to_a
      unless locked.map(&:id) == ids
        raise Provider::AccountData::StaleWriter, "Generation financial accounts have inconsistent ownership"
      end
    end

    def snapshot(external)
      link = external.account_provider
      account = external.current_account
      if link && (account.nil? || account.family_id != connection.family_id || link.family_id != connection.family_id)
        raise Provider::AccountData::StaleWriter, "Generation account linkage has inconsistent ownership"
      end
      publish = external.active? && account && Account.visible.where(id: account.id).exists?
      policy = publish && Account::SourcePolicy.active.lock.find_by(account: account, resource: resource)
      raise Provider::AccountData::StaleWriter, "Linked account has no source selection for this resource" if publish && !policy
      authorization_ids = external.provider_authorization_accounts.pluck(:provider_authorization_id)
      # Match revocation's parent-before-membership lock order. Recheck the set
      # after locking: a membership cannot silently switch to an unlocked grant.
      authorizations = connection.provider_authorizations.where(id: authorization_ids).order(:id).lock.index_by(&:id)
      memberships = external.provider_authorization_accounts.order(:id).lock.to_a
      unless (memberships.map(&:provider_authorization_id) - authorizations.keys).empty?
        raise Provider::AccountData::StaleWriter, "Generation account authorization changed while acquiring its lock"
      end
      if memberships.any? && memberships.none? { |membership| membership.active? && authorizations.fetch(membership.provider_authorization_id).usable? }
        raise Provider::AccountData::StaleWriter, "Account has no usable provider authorization"
      end
      { "external_account_id" => external.id, "status" => external.status, "resource" => resource, "identity_namespace" => external.identity_namespace,
        "account_id" => account&.id, "account_provider_id" => link&.id,
        "account_currency" => account&.currency, "accountable_type" => account&.accountable_type, "accountable_id" => account&.accountable_id,
        "account_provider_revision" => link&.lock_version,
        "publication" => publish ? "ledger" : "retained",
        "source_policy_version" => policy ? policy.id : nil,
        "authorizations" => memberships.map do |membership|
          authorization = authorizations.fetch(membership.provider_authorization_id)
          { "id" => authorization.id, "membership_id" => membership.id, "membership_status" => membership.status,
            "membership_revision" => membership.lock_version, "authorization_revision" => authorization.lock_version,
            "status" => authorization.status, "expires_at" => authorization.expires_at&.utc&.iso8601(6),
            "updated_at" => authorization.updated_at.utc.iso8601(6) }
        end }
    end
end
