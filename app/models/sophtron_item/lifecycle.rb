# Public settings commands retain the admitted source through HTTP, link writes
# and scheduling. Financial row transactions begin only after remote discovery.
class SophtronItem::Lifecycle
  Fence = Provider::AccountData::LegacyWriterFence

  def initialize(item)
    @item = item
  end

  def connect_institution(institution_id:, institution_name:, username:, password:, new_institution: false)
    with_item do |item|
      item.ensure_customer!
      request_identity = connection_identity(item)
      clone = new_institution && connected_source?(item)
      response = Provider::Sophtron.response_data!(item.sophtron_provider.create_user_institution(
        institution_id: institution_id, username: username, password: password, pin: ""
      )).with_indifferent_access
      job_id = response[:JobID] || response[:job_id]
      institution = response[:UserInstitutionID] || response[:user_institution_id]
      if job_id.blank? || institution.blank?
        raise Provider::Sophtron::Error.new("Sophtron did not return JobID and UserInstitutionID", :invalid_response)
      end

      # An unsaved clone cannot be migrated while the original permit protects
      # the request. Do not acquire a different item's permit inside this one.
      SophtronItem.transaction do
        item.lock!
        unless connection_identity(item) == request_identity && clone == (new_institution && connected_source?(item))
          raise Fence::OwnershipChanged, "Sophtron connection changed during institution creation"
        end
        SophtronItem::LegacyAccess.with_item(item, operation: :lifecycle) do |current|
          target = if clone
            current.family.sophtron_items.build(current.attributes.slice(
              "name", "user_id", "access_key", "base_url", "customer_id",
              "customer_name", "raw_customer_payload", "sync_start_date"
            ))
          else
            current
          end
          target.update!(name: current.name.presence || I18n.t("sophtron_items.defaults.name"),
            institution_id: institution_id, institution_name: institution_name,
            user_institution_id: institution, current_job_id: job_id,
            raw_job_payload: response, job_status: nil, last_connection_error: nil, status: :good)
          target
        end
      end
    end
  end

  def link_accounts(account_ids:, account_type:)
    with_item do |item|
      accounts_data = item.fetch_remote_accounts(force: true)
      created, linked, invalid = [], [], []
      account_ids.each do |id|
        data = accounts_data.find { |row| SophtronItem.external_account_id(row).to_s == id.to_s }
        next unless data
        if data[:account_name].blank?
          invalid << id
          next
        end

        source = item.upsert_sophtron_account(data)
        SophtronAccount.transaction do
          source = locked_source(item, source.id)
          if linked?(source)
            linked << data[:account_name]
          else
            created << create_linked_account(item, source, account_type,
              name: data[:account_name], balance: 0, currency: data[:currency] || "USD")
          end
        end
      end
      item.start_initial_load_later if created.any?
      { created_accounts: created, already_linked_accounts: linked, invalid_accounts: invalid }
    end
  end

  def link_existing_account(account_id:, sophtron_account_id:)
    with_item do |item|
      # Reject another family's selection before discovery or snapshot writes.
      account = Account.uncached { item.family.accounts.find(account_id) }
      next { error: :account_already_linked } if AccountProvider.uncached { account.account_providers.exists? }
      data = item.fetch_remote_accounts(force: true).find do |row|
        SophtronItem.external_account_id(row).to_s == sophtron_account_id.to_s
      end
      next { error: :sophtron_account_not_found } unless data
      next { error: :invalid_account_name } if data[:account_name].blank?

      source = item.upsert_sophtron_account(data)
      result = Account.transaction do
        account = item.family.accounts.lock.find(account.id)
        source = locked_source(item, source.id)
        next { error: :account_already_linked } if AccountProvider.uncached { account.account_providers.exists? }
        next { error: :sophtron_account_already_linked } if linked?(source)

        AccountProvider.create!(account: account, provider: source)
        { account: account }
      end
      item.start_initial_load_later unless result[:error]
      result
    end
  end

  def complete_account_setup(account_types:, account_subtypes:)
    with_item do |item|
      created, skipped = [], 0
      SophtronAccount.transaction do
        account_types.keys.sort_by(&:to_s).each do |id|
          type = account_types[id]
          if type.blank? || type == "skip"
            skipped += 1
            next
          end
          next unless Provider::SophtronAdapter.supported_account_types.include?(type)
          source = item.sophtron_accounts.lock.find_by(id: id)
          next unless source
          Fence.scoped_accounts!(item, [ source ])
          next if linked?(source)

          subtype = account_subtypes[id]
          subtype = "credit_card" if type == "CreditCard" && subtype.blank?
          created << create_linked_account(item, source, type, subtype: subtype,
            name: source.name, balance: source.balance || 0, currency: source.currency || "USD")
        end
      end
      item.start_initial_load_later if created.any?
      { created_accounts: created, skipped_count: skipped }
    end
  end

  def toggle_manual_sync(institution_key: nil)
    with_item do |item|
      SophtronItem.transaction do
        item.lock!
        sources = item.sophtron_accounts.order(:id).lock.to_a
        sources = Fence.scoped_accounts!(item, sources)
        selected = institution_key.blank? ? sources : sources.select { |source| source.institution_key.to_s == institution_key.to_s }
        if selected.any?
          enabled = item.manual_sync? ? false : selected.none?(&:manual_sync?)
          if item.manual_sync?
            item.sophtron_accounts.where(id: sources.map(&:id) - selected.map(&:id)).update_all(manual_sync: true, updated_at: Time.current)
          end
          item.sophtron_accounts.where(id: selected.map(&:id)).update_all(manual_sync: enabled, updated_at: Time.current)
          item.update!(manual_sync: false) unless enabled
        elsif institution_key.present?
          next { error: :no_linked_accounts }
        else
          item.update!(manual_sync: !item.manual_sync?)
          enabled = item.manual_sync?
        end
        { enabled: enabled }
      end
    end
  end

  def disconnect
    SophtronItem::LegacyAccess.with_item(@item, operation: :lifecycle) do |item|
      results = item.unlink_all!(dry_run: false)
      item.destroy_later unless results.any? { |result| result[:error].present? }
      results
    end
  end

  private
    def with_item
      SophtronItem::LegacyAccess.with_item(@item, operation: :lifecycle) do |item|
        raise Fence::OwnershipChanged, "Sophtron item is scheduled for deletion" if item.scheduled_for_deletion?
        yield item
      end
    end

    def connected_source?(item)
      item.user_institution_id.present? || item.current_job_id.present? ||
        item.institution_id.present? || item.institution_name.present? || item.sophtron_accounts.exists?
    end

    def connection_identity(item)
      item.attributes.slice("id", "family_id", "user_id", "access_key", "base_url", "customer_id",
        "user_institution_id", "institution_id", "current_job_id", "scheduled_for_deletion")
    end

    def locked_source(item, id)
      source = item.sophtron_accounts.lock.find(id)
      Fence.scoped_accounts!(item, [ source ]).sole
    end

    def linked?(source)
      AccountProvider.uncached do
        AccountProvider.where(provider_type: "SophtronAccount", provider_id: source.id).exists?
      end
    end

    def create_linked_account(item, source, type, name:, balance:, currency:, subtype: nil)
      account = Account.create_and_sync({ family: item.family, name: name, balance: balance,
        currency: currency, accountable_type: type,
        accountable_attributes: subtype.present? ? { subtype: subtype } : {} }, skip_initial_sync: true)
      AccountProvider.create!(account: account, provider: source)
      account
    end
end
