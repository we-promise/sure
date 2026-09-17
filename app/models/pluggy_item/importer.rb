# frozen_string_literal: true

class PluggyItem::Importer
  def initialize(pluggy_item, pluggy_provider:, sync: nil)
    @pluggy_item = pluggy_item
    @pluggy_provider = pluggy_provider
    @sync = sync
  end

  def import
    result = { accounts: 0, transactions: 0, investments: 0, processed: [], errors: [] }

    # Normalize to a bare hostname to match PluggyAdapter#institution_domain.
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

    # Container pick is sticky across syncs (#investment_container_id) because
    # /accounts order is unstable.
    investment_account_ids = accounts_data.filter_map { |acc| acc["id"] if investment_account?(acc) }
    container_id = investment_container_id(investment_account_ids)

    accounts_data.each do |acc|
      begin
        pluggy_account = PluggyAccount.upsert_from_pluggy!(acc, pluggy_item: @pluggy_item)

        transactions = @pluggy_provider.get_account_transactions(account_id: acc["id"])
        pluggy_account.upsert_pluggy_transactions_snapshot!(transactions)
        result[:transactions] += transactions.size

        # Investments are item-scoped, so the snapshot attaches to ONE container
        # only — otherwise HoldingsProcessor re-imports the same rows under each
        # account and the balance multi-counts. The sticky container_id keeps the
        # snapshot from jumping accounts on a /accounts reorder. Trades stay out
        # of scope (phase 2), so activities_fetch_pending flags the item as still
        # fetching.
        if acc["id"] == container_id
          pluggy_account.upsert_pluggy_holdings_snapshot!(investments_data)
          pluggy_account.upsert_pluggy_activities_snapshot!(activities_data)
          pluggy_account.update!(activities_fetch_pending: true)
        end

        PluggyAccount::Processor.new(pluggy_account).process
        result[:processed] << pluggy_account.id
      rescue Provider::Pluggy::AuthenticationError
        # Item-wide, not account-scoped: re-raise so the top-level rescue fires once.
        raise
      rescue => e
        # Isolate per-account failures so one bad account can't abort the whole
        # import. Mirrors EnableBanking/Lunchflow.
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

    # Investments may exist at item level with no investment-type account in
    # /accounts; synthesize a linkable container in that case. Skip when the loop
    # already attached holdings to a real container.
    if investments_data.any? && container_id.blank?
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

    # Sticky container pick: prefer the investment-type account already carrying
    # a non-empty snapshot, else the lexically-smallest id in /accounts. Returns
    # nil when there's no investment-type account (caller synthesizes).
    def investment_container_id(investment_account_ids)
      existing = @pluggy_item.pluggy_accounts
        .where(account_type: "investment")
        .where("jsonb_array_length(raw_holdings_payload) > 0")
        .order(:pluggy_account_id)
        .first
      return existing.pluggy_account_id if existing
      investment_account_ids.min
    end

    # Synthesize a linkable investment container when /accounts has no
    # investment-type row. Stable per-item id so re-imports upsert the same row.
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

    # Bare hostname (e.g. "https://bank.example" → "bank.example"), mirroring
    # PluggyAdapter#institution_domain. Blank/invalid → nil.
    def normalize_institution_domain(url)
      return nil if url.blank?
      URI.parse(url).host&.gsub(/^www\./, "")
    rescue URI::InvalidURIError
      Rails.logger.warn("Invalid institution URL for PluggyItem #{@pluggy_item.id}: #{url}")
      nil
    end
end
