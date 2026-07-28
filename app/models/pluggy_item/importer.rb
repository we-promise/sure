# frozen_string_literal: true

class PluggyItem::Importer
  def initialize(pluggy_item, pluggy_provider:, sync: nil)
    @pluggy_item = pluggy_item
    @pluggy_provider = pluggy_provider
    @sync = sync
  end

  def import
    result = { accounts: 0, transactions: 0, investments: 0, processed: [] }

    # Institution metadata from the item's connector
    item = @pluggy_provider.get_item
    connector = item["connector"] || {}
    @pluggy_item.update!(
      institution_name: connector["name"],
      institution_domain: connector["website_url"]
    )

    # Item-scoped fetches (Pluggy investments are item-scoped, not account-scoped)
    investments_data = @pluggy_provider.get_investments
    activities_data = investments_data.each_with_object([]) do |inv, memo|
      memo.concat(@pluggy_provider.get_investment_transactions(investment_id: inv["id"]))
    end
    result[:investments] = investments_data.size

    # Accounts + per-account banking transactions
    accounts_data = @pluggy_provider.get_accounts
    @pluggy_item.upsert_pluggy_snapshot!(accounts_data)
    result[:accounts] = accounts_data.size

    investment_container_upserted = false

    accounts_data.each do |acc|
      pluggy_account = PluggyAccount.upsert_from_pluggy!(acc, pluggy_item: @pluggy_item)

      transactions = @pluggy_provider.get_account_transactions(account_id: acc["id"])
      pluggy_account.upsert_pluggy_transactions_snapshot!(transactions)
      result[:transactions] += transactions.size

      if investment_account?(acc)
        # Pluggy exposes investments at the item level; attach them to the
        # investment-typed container account so HoldingsProcessor can read them.
        # Activities (investment transactions) are snapshotted but Trades import is
        # explicitly OUT OF SCOPE for this PR (phase 2); leave activities_fetch_pending
        # true so the generated syncing? override flags the item as still fetching.
        pluggy_account.upsert_pluggy_holdings_snapshot!(investments_data)
        pluggy_account.upsert_pluggy_activities_snapshot!(activities_data)
        pluggy_account.update!(activities_fetch_pending: true)
        investment_container_upserted = true
      end

      PluggyAccount::Processor.new(pluggy_account).process
      result[:processed] << pluggy_account.id
    end

    # Pluggy frequently returns investments at the ITEM level even when /accounts
    # exposes no investment-type container (only credit/checking). Without a
    # PluggyAccount row the holdings never surface in unlinked_pluggy_accounts, so
    # the user can never link them — manifesting as "investments didn't arrive"
    # (yet visible on Pluggy's dashboard) plus "no accounts yet" on the accounts
    # screen. Synthesize a container so they become a linkable Investment account.
    # When /accounts DID include an investment-typed account the loop above already
    # attached holdings there, so skip synthesis to avoid a duplicate container.
    if investments_data.any? && !investment_container_upserted
      synthetic = synthesize_investment_account!(investments_data, activities_data)
      PluggyAccount::Processor.new(synthetic).process
      result[:processed] << synthetic.id
    end

    result
  rescue Provider::Pluggy::AuthenticationError
    @pluggy_item.update!(status: :requires_update)
    raise
  end

  private

    def investment_account?(acc)
      acc["type"].to_s.downcase == "investment"
    end

    # Builds an investment-typed PluggyAccount from the item-scoped /investments
    # payload so the holdings become a linkable Investment account even when
    # /accounts exposes no investment-type container. The synthetic id is stable
    # per item so re-imports upsert the same row rather than duplicating it.
    def synthesize_investment_account!(investments_data, activities_data)
      synthetic_hash = {
        "id" => "synthetic-investment-#{@pluggy_item.id}",
        "name" => "Investments",
        "type" => "investment",
        "currencyCode" => investments_data.first&.dig("currencyCode").presence || "USD",
        "balance" => 0,
        "status" => "ACTIVE"
      }
      pluggy_account = PluggyAccount.upsert_from_pluggy!(synthetic_hash, pluggy_item: @pluggy_item)
      pluggy_account.upsert_pluggy_holdings_snapshot!(investments_data)
      pluggy_account.upsert_pluggy_activities_snapshot!(activities_data)
      pluggy_account.update!(activities_fetch_pending: true)
      pluggy_account
    end
end
