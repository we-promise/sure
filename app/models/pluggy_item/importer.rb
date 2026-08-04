# frozen_string_literal: true

class PluggyItem::Importer
  def initialize(pluggy_item, pluggy_provider:, sync: nil)
    @pluggy_item = pluggy_item
    @pluggy_provider = pluggy_provider
    @sync = sync
  end

  def import
    result = { accounts: 0, transactions: 0, investments: 0, processed: [], errors: [] }

    # Institution metadata from the item's connector. Normalize the connector's
    # website_url to a bare hostname so the cached institution_domain column
    # matches the bare-hostname contract PluggyAdapter#institution_domain derives
    # off metadata (DRY: same URI.parse + www strip), rather than the importer
    # caching the full URL while the adapter returns a bare host.
    item = @pluggy_provider.get_item
    connector = item["connector"] || {}
    @pluggy_item.update!(
      institution_name: connector["name"],
      institution_domain: normalize_institution_domain(connector["website_url"])
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
      begin
        pluggy_account = PluggyAccount.upsert_from_pluggy!(acc, pluggy_item: @pluggy_item)

        transactions = @pluggy_provider.get_account_transactions(account_id: acc["id"])
        pluggy_account.upsert_pluggy_transactions_snapshot!(transactions)
        result[:transactions] += transactions.size

        if investment_account?(acc)
          # Pluggy investments are ITEM-scoped (one /investments array for the whole
          # item), so they attach to exactly ONE investment-typed container — not to
          # every investment-type account /accounts happens to return. The old loop
          # snapshotted the full item holdings onto EACH investment-type PluggyAccount;
          # HoldingsProcessor (l61) then re-imported the same rows under each account's
          # own account_provider_id, and once AutoSetup / the setup wizard linked them,
          # Processor#upsert_investment_balance summed the FULL item value per linked
          # account → the family's investment balance multi-counted by the number of
          # investment-type accounts. Use the FIRST investment-type account as the
          # sole container; any further investment-type accounts keep their banking
          # transactions + processing above but carry no holdings (balance 0 — a
          # known empty-container state, not a silent over-report). The container flag
          # already gates the synthesis path at l92, so "real container present → no
          # synthetic" keeps working. Activities (investment transactions) are
          # snapshotted on the container only; Trades import stays OUT OF SCOPE
          # (phase 2), so activities_fetch_pending stays true on it to flag the item
          # as still fetching.
          unless investment_container_upserted
            pluggy_account.upsert_pluggy_holdings_snapshot!(investments_data)
            pluggy_account.upsert_pluggy_activities_snapshot!(activities_data)
            pluggy_account.update!(activities_fetch_pending: true)
            investment_container_upserted = true
          end
        end

        PluggyAccount::Processor.new(pluggy_account).process
        result[:processed] << pluggy_account.id
      rescue Provider::Pluggy::AuthenticationError
        # Auth failure is item-wide, not account-scoped: re-raise so the top-level
        # rescue marks the item requires_update and captures once, instead of once
        # per account plus a partial import that reads as success to support.
        raise
      rescue => e
        # Isolate per-account failures so one bad account can't abort the whole
        # item import: record it, surface via DebugLogEntry for /settings/debug,
        # and continue. Mirrors EnableBanking/Lunchflow importer isolation.
        result[:errors] << { account_id: acc["id"], error_class: e.class.name, error: e.message }
        DebugLogEntry.capture(
          category: "provider_sync_error",
          level: "warn",
          message: "Pluggy import failed for account #{acc['id']}; skipping and continuing with remaining accounts",
          source: self.class.name,
          provider_key: "pluggy",
          family: @pluggy_item.family,
          account_provider: pluggy_account&.account_provider,
          metadata: { account_id: acc["id"], pluggy_account_id: pluggy_account&.id, error_class: e.class.name, error: e.message }
        )
      end
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
  rescue Provider::Pluggy::AuthenticationError => e
    @pluggy_item.update!(status: :requires_update)
    DebugLogEntry.capture(
      category: "provider_sync_error",
      level: "error",
      message: "Pluggy authentication failed for item #{@pluggy_item.id}; marking requires_update",
      source: self.class.name,
      provider_key: "pluggy",
      family: @pluggy_item.family,
      metadata: { pluggy_item_id: @pluggy_item.id, error_class: e.class.name, error: e.message }
    )
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

    # Derive a bare hostname from the connector's website_url (e.g.
    # "https://bank.example" → "bank.example"), mirroring
    # PluggyAdapter#institution_domain so the importer-side cache and the
    # adapter-side derivation agree on the bare-hostname contract. Blank/invalid
    # URLs fall back to nil rather than persisting a malformed value.
    def normalize_institution_domain(url)
      return nil if url.blank?
      URI.parse(url).host&.gsub(/^www\./, "")
    rescue URI::InvalidURIError
      Rails.logger.warn("Invalid institution URL for PluggyItem #{@pluggy_item.id}: #{url}")
      nil
    end
end
