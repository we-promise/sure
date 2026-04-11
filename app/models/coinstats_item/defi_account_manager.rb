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
  # Returns true on success, false on failure.
  def sync_wallet!(address:, blockchain:, provider:)
    normalized_address = address.to_s.downcase
    normalized_blockchain = blockchain.to_s.downcase

    response = provider.get_wallet_defi(address: address, connection_id: blockchain)
    unless response.success?
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - DeFi fetch failed for #{normalized_blockchain}:#{normalized_address}"
      return false
    end

    defi_data = response.data.to_h.with_indifferent_access
    protocols = Array(defi_data[:protocols])
    active_defi_ids = []
    had_upsert_failures = false

    protocols.each do |protocol|
      protocol = protocol.with_indifferent_access

      Array(protocol[:investments]).each do |investment|
        investment = investment.with_indifferent_access

        Array(investment[:assets]).each do |asset|
          asset = asset.with_indifferent_access
          next if asset[:amount].to_f.zero?
          next if asset[:coinId].blank? && asset[:symbol].blank?

          account_id = build_account_id(protocol, investment, asset, blockchain: normalized_blockchain)

          if upsert_account!(address: normalized_address, blockchain: normalized_blockchain, protocol: protocol, investment: investment, asset: asset, account_id: account_id)
            active_defi_ids << account_id
          else
            had_upsert_failures = true
          end
        end
      end
    end

    # Skip zero-out when upserts failed — active_defi_ids is incomplete and we'd risk
    # zeroing accounts that are still active but failed to save this cycle.
    return false if had_upsert_failures

    zero_out_inactive_accounts!(normalized_address, normalized_blockchain, active_defi_ids)
    true
  rescue => e
    Rails.logger.warn "CoinstatsItem::DefiAccountManager - Sync failed for #{blockchain}:#{address}: #{e.message}"
    false
  end

  # Creates the local Account for a DeFi CoinstatsAccount if it doesn't exist yet.
  def ensure_local_account!(coinstats_account)
    return false if coinstats_account.account.present?

    account = Account.create_and_sync({
      family: coinstats_item.family,
      name: coinstats_account.name,
      balance: coinstats_account.current_balance || 0,
      cash_balance: 0,
      currency: coinstats_account.currency,
      accountable_type: "Crypto",
      accountable_attributes: {
        subtype: "wallet",
        tax_treatment: "taxable"
      }
    }, skip_initial_sync: true)

    AccountProvider.create!(account: account, provider: coinstats_account)
    true
  rescue ActiveRecord::RecordNotUnique
    # Another concurrent sync created the AccountProvider; destroy the orphaned Account we just created.
    account&.destroy
    false
  end

  private

    # Builds a stable, unique account_id for a DeFi asset position.
    # Format: "defi:<blockchain>:<protocol_id>:<investment_type>:<coin_id>:<asset_title>"
    # Blockchain is included to avoid collisions when the same wallet address exists on
    # multiple EVM-compatible chains (e.g. Ethereum and Polygon).
    def build_account_id(protocol, investment, asset, blockchain:)
      chain = blockchain.to_s.downcase.gsub(/\s+/, "_").presence || "unknown"
      protocol_id = protocol[:id].to_s.downcase.gsub(/\s+/, "_").presence || "unknown"
      coin_id = (asset[:coinId] || asset[:symbol]).to_s.downcase
      title = asset[:title].to_s.downcase.gsub(/\s+/, "_").presence || "position"
      investment_type = investment[:name].to_s.downcase.gsub(/\s+/, "_").presence
      parts = [ "defi", chain, protocol_id, coin_id, title ]
      parts.insert(3, investment_type) if investment_type.present?
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

    # Returns true on success, false on failure (so the caller can track active positions correctly).
    def upsert_account!(address:, blockchain:, protocol:, investment:, asset:, account_id:)
      coinstats_account = coinstats_item.coinstats_accounts.find_or_initialize_by(
        account_id: account_id,
        wallet_address: address
      )

      # The DeFi API returns asset.price as a TotalValueDto (total position value, not per-token price).
      # Store it as `balance` so inferred_current_balance uses it directly instead of quantity * price.
      # Guard against a missing USD key falling back to the whole hash (which would raise on .to_f).
      total_balance_usd = if asset[:price].is_a?(Hash)
        price_hash = asset[:price].with_indifferent_access
        (price_hash[:USD] || price_hash["USD"] || 0).to_f
      else
        asset[:price].to_f
      end

      # Convert the USD balance to the family's base currency for consistent portfolio reporting.
      # convert_usd_balance returns the actual currency used — it may fall back to "USD" if the
      # exchange rate is unavailable, so we use the returned currency rather than assuming success.
      balance, actual_currency = convert_usd_balance(total_balance_usd, family_currency)
      quantity = asset[:amount].to_f
      per_token_price = quantity > 0 ? balance / quantity : 0

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
        balance: balance,
        priceUsd: per_token_price,
        asset_title: asset[:title],
        currency: actual_currency,
        institution_logo: protocol[:logo]
      }.compact

      coinstats_account.name = build_account_name(protocol, asset) unless coinstats_account.persisted?
      coinstats_account.currency = actual_currency
      coinstats_account.raw_payload = snapshot
      coinstats_account.current_balance = coinstats_account.inferred_current_balance(snapshot)
      coinstats_account.institution_metadata = { logo: protocol[:logo] }.compact
      coinstats_account.save!

      ensure_local_account!(coinstats_account)
      true
    rescue => e
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - Failed to upsert account #{account_id}: #{e.message}"
      false
    end

    # Sets balance to zero for DeFi accounts no longer present in the API response.
    def zero_out_inactive_accounts!(address, blockchain, active_defi_ids)
      coinstats_item.coinstats_accounts.where(wallet_address: address).each do |account|
        raw = account.raw_payload.to_h.with_indifferent_access
        next unless raw[:source] == "defi"
        next unless raw[:blockchain].to_s.casecmp?(blockchain.to_s)
        next if active_defi_ids.include?(account.account_id)

        account.update!(current_balance: 0, raw_payload: raw.merge(amount: 0, balance: 0, priceUsd: 0))
      end
    end

    def family_currency
      coinstats_item.family.currency.presence || "USD"
    end

    # Converts a USD amount to the target currency using Money exchange rates.
    # Returns [amount, currency] so the caller always knows what currency the amount is in.
    # Falls back to [usd_amount, "USD"] if conversion is unavailable.
    def convert_usd_balance(usd_amount, target_currency)
      return [ usd_amount, "USD" ] if target_currency == "USD" || usd_amount.zero?

      [ Money.new(usd_amount, "USD").exchange_to(target_currency).amount, target_currency ]
    rescue => e
      Rails.logger.warn "CoinstatsItem::DefiAccountManager - FX conversion USD->#{target_currency} failed: #{e.message}"
      [ usd_amount, "USD" ]
    end
end
