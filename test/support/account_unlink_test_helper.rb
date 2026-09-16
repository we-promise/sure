module AccountUnlinkTestHelper
  include OnchainTestHelper

  UnlinkContext = Data.define(:account, :items, :sources)

  def with_unlink_account
    account = users(:family_admin).family.accounts.create!(owner: users(:family_admin), name: "Unlink test account",
      currency: "USD", balance: 1000, accountable: Depository.new)
    context = UnlinkContext.new(account: account, items: [], sources: [])
    begin
      yield context
    ensure
      # These are isolated test records. Avoid remote provider-delete callbacks
      # and leave existing fixtures unchanged in this real-commit test suite.
      Account::SourcePolicy.where(account_id: account.id).delete_all
      AccountProvider.where(account_id: account.id).delete_all
      if Account.exists?(account.id)
        account.reload.update_columns(plaid_account_id: nil, simplefin_account_id: nil)
        account.destroy!
      end
      context.sources.each { |source| source.class.where(id: source.id).delete_all }
      context.items.each { |item| item.class.where(id: item.id).delete_all }
    end
  end

  def add_unlink_source(context, key, link: true)
    family = context.account.family
    item = case key
    when "plaid" then PlaidItem.create!(family: family, name: "Unlink Plaid", access_token: "private-token", plaid_id: SecureRandom.uuid)
    when "simplefin" then SimplefinItem.create!(family: family, name: "Unlink SimpleFIN", access_url: "https://user:secret@bridge.example/access")
    when "coinstats" then CoinstatsItem.create!(family: family, name: "Unlink CoinStats", api_key: "private-key")
    when "snaptrade" then SnaptradeItem.create!(family: family, name: "Unlink SnapTrade")
    when "onchain_wallet" then create_onchain_wallet_item(family: family)
    else raise ArgumentError, "Unknown unlink fixture"
    end
    context.items << item
    source = case key
    when "plaid" then item.plaid_accounts.create!(plaid_id: SecureRandom.uuid, name: "Checking", plaid_type: "depository", currency: "USD", current_balance: 1000)
    when "simplefin" then item.simplefin_accounts.create!(account_id: SecureRandom.uuid, name: "Checking", account_type: "checking", currency: "USD", current_balance: 1000)
    when "coinstats" then item.coinstats_accounts.create!(account_id: SecureRandom.uuid, name: "Wallet", currency: "USD", current_balance: 1000)
    when "snaptrade" then item.snaptrade_accounts.create!(snaptrade_account_id: SecureRandom.uuid, name: "Brokerage", currency: "USD", current_balance: 1000)
    when "onchain_wallet" then create_onchain_wallet_account(item: item)
    end
    context.sources << source
    AccountProvider.create!(account: context.account, provider: source) if link
    source
  end

  def unlink_holding(account, link)
    account.holdings.create!(security: securities(:aapl), account_provider: link, date: Date.current,
      qty: 2, price: 100, amount: 200, currency: "USD")
  end
end
