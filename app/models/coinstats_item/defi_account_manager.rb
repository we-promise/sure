# frozen_string_literal: true

# Manages DeFi/staking accounts for a CoinStats wallet connection.
# Discovers staking, LP, and yield farming positions via the CoinStats DeFi API
# and keeps the corresponding CoinstatsAccounts up to date.
class CoinstatsItem::DefiAccountManager
  attr_reader :coinstats_item

  def initialize(coinstats_item)
    @coinstats_item = coinstats_item
  end

  # Fetches DeFi positions for the given wallet and creates/updates CoinstatsAccounts.
  # Positions that disappear from the API (fully unstaked) are zeroed out.
  def sync_wallet!(address:, blockchain:, provider:)
    response = provider.get_wallet_defi(address: address, connection_id: blockchain)
    unless response.success?
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - DeFi fetch failed for #{blockchain}:#{address}"
      return
    end

    defi_data = response.data.to_h.with_indifferent_access
    protocols = Array(defi_data[:protocols])
    active_defi_ids = []

    protocols.each do |protocol|
      protocol = protocol.with_indifferent_access

      Array(protocol[:investments]).each do |investment|
        investment = investment.with_indifferent_access

        Array(investment[:assets]).each do |asset|
          asset = asset.with_indifferent_access
          next if asset[:amount].to_f.zero?
          next if asset[:coinId].blank? && asset[:symbol].blank?

          account_id = build_account_id(protocol, investment, asset)
          active_defi_ids << account_id
          upsert_account!(address: address, blockchain: blockchain, protocol: protocol, investment: investment, asset: asset, account_id: account_id)
        end
      end
    end

    zero_out_inactive_accounts!(address, blockchain, active_defi_ids)
  rescue => e
    Rails.logger.warn "CoinstatsItem::DefiAccountManager - Sync failed for #{blockchain}:#{address}: #{e.message}"
  end

  # Creates the local Account for a DeFi CoinstatsAccount if it doesn't exist yet.
  def ensure_local_account!(coinstats_account)
    return false if coinstats_account.account.present?

    account = Account.create_and_sync({
      family: coinstats_item.family,
      name: coinstats_account.name,
      balance: coinstats_account.current_balance || 0,
      cash_balance: 0,
      currency: "USD",
      accountable_type: "Crypto",
      accountable_attributes: {
        subtype: "wallet",
        tax_treatment: "taxable"
      }
    }, skip_initial_sync: true)

    AccountProvider.create!(account: account, provider: coinstats_account)
    true
  end

  private

    # Builds a stable, unique account_id for a DeFi asset position.
    # Format: "defi:<protocol_id>:<investment_type>:<coin_id>:<asset_title>"
    def build_account_id(protocol, investment, asset)
      protocol_id = protocol[:id].to_s.downcase.gsub(/\s+/, "_").presence || "unknown"
      coin_id = (asset[:coinId] || asset[:symbol]).to_s.downcase
      title = asset[:title].to_s.downcase.gsub(/\s+/, "_").presence || "position"
      investment_type = investment[:name].to_s.downcase.gsub(/\s+/, "_").presence
      parts = [ "defi", protocol_id, coin_id, title ]
      parts.insert(2, investment_type) if investment_type.present?
      parts.join(":")
    end

    def build_account_name(protocol, asset)
      protocol_name = protocol[:name].to_s
      symbol = asset[:symbol].to_s.upcase

      case asset[:title].to_s.downcase
      when "deposit", "supplied"
        "#{symbol} (#{protocol_name} Staking)"
      when "reward", "yield"
        "#{symbol} (#{protocol_name} Rewards)"
      else
        label = asset[:title].to_s.presence || "Position"
        "#{symbol} (#{protocol_name} #{label})"
      end
    end

    def upsert_account!(address:, blockchain:, protocol:, investment:, asset:, account_id:)
      coinstats_account = coinstats_item.coinstats_accounts.find_or_initialize_by(
        account_id: account_id,
        wallet_address: address
      )

      # The DeFi API returns asset.price as a TotalValueDto (total position value, not per-token price).
      # Store it as `balance` so inferred_current_balance uses it directly instead of quantity * price.
      # Also derive the per-token price so the holdings processor records the correct share price.
      price_data = asset[:price].is_a?(Hash) ? asset[:price].with_indifferent_access : {}
      total_balance_usd = (price_data[:USD] || price_data["USD"] || asset[:price]).to_f
      quantity = asset[:amount].to_f
      per_token_price_usd = quantity > 0 ? total_balance_usd / quantity : 0

      snapshot = {
        source: "defi",
        id: account_id,
        address: address,
        blockchain: blockchain,
        protocol_id: protocol[:id],
        protocol_name: protocol[:name],
        protocol_logo: protocol[:logo],
        investment_type: investment[:name],
        coinId: asset[:coinId],
        symbol: asset[:symbol],
        name: asset[:symbol].to_s.upcase,
        amount: asset[:amount],
        balance: total_balance_usd,
        priceUsd: per_token_price_usd,
        asset_title: asset[:title],
        currency: "USD",
        institution_logo: protocol[:logo]
      }.compact

      coinstats_account.name = build_account_name(protocol, asset) unless coinstats_account.persisted?
      coinstats_account.currency = "USD"
      coinstats_account.raw_payload = snapshot
      coinstats_account.current_balance = coinstats_account.inferred_current_balance(snapshot)
      coinstats_account.institution_metadata = { logo: protocol[:logo] }.compact
      coinstats_account.save!

      ensure_local_account!(coinstats_account)
    rescue => e
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - Failed to upsert account #{account_id}: #{e.message}"
    end

    # Sets balance to zero for DeFi accounts no longer present in the API response.
    def zero_out_inactive_accounts!(address, blockchain, active_defi_ids)
      coinstats_item.coinstats_accounts.where(wallet_address: address).each do |account|
        raw = account.raw_payload.to_h.with_indifferent_access
        next unless raw[:source] == "defi"
        next unless raw[:blockchain].to_s.casecmp?(blockchain.to_s)
        next if active_defi_ids.include?(account.account_id)

        account.update!(current_balance: 0, raw_payload: raw.merge(amount: 0))
      end
    end
end
