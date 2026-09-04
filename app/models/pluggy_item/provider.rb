# frozen_string_literal: true

class PluggyItem::Provider
  attr_reader :pluggy_item
  delegate :client_id, :client_secret, to: :pluggy_item

  def initialize(pluggy_item)
    @pluggy_item = pluggy_item
  end

  def item_id
    pluggy_item.pluggy_item_id
  end

  def get_accounts(type: nil)
    Provider::Pluggy.get_accounts(item_id:, client_id:, client_secret:, type:)
  end

  def get_account_transactions(account_id:, **opts)
    Provider::Pluggy.get_account_transactions(account_id:, client_id:, client_secret:, **opts)
  end

  def get_investments
    Provider::Pluggy.get_investments(item_id:, client_id:, client_secret:)
  end

  def get_investment_transactions(investment_id:)
    Provider::Pluggy.get_investment_transactions(investment_id:, client_id:, client_secret:)
  end

  def get_item
    Provider::Pluggy.get_item(item_id:, client_id:, client_secret:)
  end

  def delete_item
    Provider::Pluggy.delete_item(item_id:, client_id:, client_secret:)
  end

  def connect_token(**opts)
    Provider::Pluggy.connect_token(client_id:, client_secret:, **opts)
  end
end
