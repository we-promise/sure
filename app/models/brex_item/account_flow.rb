# frozen_string_literal: true

class BrexItem::AccountFlow < ProviderItem::AccountFlow
  SelectionResult = Class.new(superclass::SelectionResult) do
    def brex_item = item
  end

  def self.cache_sensitive_params
    %i[token base_url]
  end

  def initialize(family:, brex_item_id: nil, brex_item: nil, item_id: nil, item: nil)
    super(family: family, item_id: brex_item_id || item_id, item: brex_item || item)
  end

  alias_method :brex_item, :item
  alias_method :brex_item_id, :item_id
  alias_method :unlinked_brex_accounts, :unlinked_provider_accounts

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

    def provider_account_snapshot_changed?(brex_account, account_data)
      snapshot = account_data.with_indifferent_access
      balances = snapshot.slice(:current_balance, :available_balance, :account_limit)

      expected = {
        account_kind: BrexAccount.kind_for(snapshot),
        account_status: snapshot[:status],
        account_type: snapshot[:type],
        available_balance: BrexAccount.money_to_decimal(balances[:available_balance]),
        current_balance: BrexAccount.money_to_decimal(balances[:current_balance]),
        account_limit: BrexAccount.money_to_decimal(balances[:account_limit]),
        currency: BrexAccount.currency_code_from_money(balances[:current_balance] || balances[:available_balance] || balances[:account_limit]),
        name: BrexAccount.name_for(snapshot),
        raw_payload: BrexAccount.sanitize_payload(account_data)
      }

      expected.any? { |attribute, value| brex_account.public_send(attribute) != value }
    end
end
