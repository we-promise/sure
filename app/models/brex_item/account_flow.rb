# frozen_string_literal: true

class BrexItem::AccountFlow < ProviderItem::AccountFlow
  require_dependency "brex_item/account_flow/setup"

  include Setup

  # Setup is a nested module, so its constant lookup does not see constants
  # this class inherits.
  NoApiTokenError = ProviderItem::AccountFlow::NoApiTokenError

  SelectionResult = Class.new(superclass::SelectionResult) do
    def brex_item = item
  end

  SetupResult = Data.define(:created_accounts, :skipped_count, :failed_count) do
    def created_count = created_accounts.count
  end

  SetupCompletion = Data.define(:success, :message) do
    def success? = success
  end

  def self.cache_sensitive_params
    %i[token base_url]
  end

  def initialize(family:, brex_item_id: nil, brex_item: nil, item_id: nil, item: nil)
    super(family: family, item_id: brex_item_id || item_id, item: brex_item || item)
  end

  alias_method :brex_item, :item
  alias_method :brex_item_id, :item_id

  def link_existing_account_result(account:, brex_account_id: nil, provider_account_id: nil)
    super(account: account, provider_account_id: brex_account_id || provider_account_id)
  end

  def link_existing_account!(account:, brex_account_id: nil, provider_account_id: nil)
    super(account: account, provider_account_id: brex_account_id || provider_account_id)
  end

  private

    def provider_error_class
      Provider::Brex::BrexError
    end

    def resolve_item(id)
      BrexItem.resolve_for(family: family, brex_item_id: id)
    end

    def fetch_accounts
      provider = brex_item&.brex_provider
      raise NoApiTokenError unless provider.present?

      accounts_data = provider.get_accounts
      accounts_data[:accounts] || []
    end

    def account_offered_as?(account, accountable_type)
      case accountable_type
      when "CreditCard"
        BrexAccount.kind_for(account) == "card"
      when "Depository"
        BrexAccount.kind_for(account) == "cash"
      else
        true
      end
    end

    def upsert_provider_account!(account_id, account_data)
      brex_account = brex_item.brex_accounts.find_or_initialize_by(account_id: account_id.to_s)
      brex_account.upsert_brex_snapshot!(account_data)
      brex_account
    end

    # Setup still calls it by this name.
    alias_method :upsert_brex_account!, :upsert_provider_account!
end
