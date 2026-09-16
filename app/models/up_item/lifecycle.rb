# Source-bound commands used by the Up settings/account pickers. Each permit
# starts before client construction or an ordinary database write transaction.
class UpItem::Lifecycle
  def initialize(up_item)
    @up_item = up_item
  end

  def update_settings(attributes)
    with_item(operation: :credentials) do |item|
      item.update(attributes.to_h.stringify_keys.slice("name", "access_token", "sync_start_date"))
      item
    end
  end

  def discover_accounts
    with_item do |item|
      provider = item.up_provider
      raise StandardError, "Up provider is not configured" unless provider

      provider.get_accounts.each do |account_data|
        snapshot = account_data.with_indifferent_access
        next if snapshot[:id].blank? || snapshot[:displayName].blank?

        account = item.up_accounts.find_or_initialize_by(account_id: snapshot[:id].to_s)
        account.upsert_up_snapshot!(snapshot)
      end
      nil
    end
  end

  def link_accounts(account_ids:, account_type:)
    unless Provider::UpAdapter.supported_account_types.include?(account_type)
      raise ArgumentError, "Unsupported Up account type"
    end

    with_item do |item|
      created = []
      UpAccount.transaction do
        item.up_accounts.where(id: account_ids).order(:id).lock.each do |source|
          next if source.account_provider.present?
          created << create_linked_account(item, source, account_type)
        end
      end
      item.sync_later if created.any?
      created
    end
  end

  def link_existing_account(account_id:, up_account_id:)
    with_item do |item|
      result = Account.transaction do
        account = item.family.accounts.lock.find(account_id)
        source = item.up_accounts.lock.find_by(id: up_account_id)
        next { error: :no_account_selected } unless source
        next { error: :account_already_linked } if account.account_providers.exists?
        next { error: :up_account_already_linked } if source.account_provider.present?

        AccountProvider.create!(account: account, provider: source)
        { account: account }
      end
      item.sync_later unless result[:error]
      result
    end
  end

  def complete_account_setup(account_types:)
    with_item do |item|
      created = []
      skipped = 0
      UpAccount.transaction do
        account_types.keys.sort_by(&:to_s).each do |id|
          type = account_types[id]
          source = item.up_accounts.lock.find_by(id: id)
          next unless source

          if type.blank? || type == "skip"
            source.update!(ignored: true) unless source.account_provider.present?
            skipped += 1
          elsif Provider::UpAdapter.supported_account_types.include?(type) && source.account_provider.blank?
            created << create_linked_account(item, source, type)
          end
        end
      end
      item.sync_later if created.any?
      { created_accounts: created, skipped_count: skipped }
    end
  end

  def disconnect
    with_item do |item|
      results = item.unlink_all!(dry_run: false)
      item.destroy_later unless results.any? { |result| result[:error].present? }
      results
    end
  end

  private
    def with_item(operation: :lifecycle, &block)
      Provider::AccountData::LegacyWriterFence.with_item(@up_item, operation: operation, &block)
    end

    def create_linked_account(item, source, account_type)
      source.update!(ignored: false) if source.ignored?
      balance = source.current_balance || 0
      balance = balance.abs if account_type == "Loan"
      subtype = source.suggested_subtype if account_type == "Depository" && source.suggested_account_type == account_type

      account = Account.create_and_sync({
        family: item.family, name: source.name, balance: balance, cash_balance: balance,
        currency: source.currency || "AUD", accountable_type: account_type,
        accountable_attributes: subtype.present? ? { subtype: subtype } : {}
      }, skip_initial_sync: true)
      AccountProvider.create!(account: account, provider: source)
      account
    end
end
