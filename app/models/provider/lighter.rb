class Provider::Lighter
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end

  API_BASE_URL = "https://mainnet.zklighter.elliot.ai".freeze

  base_uri API_BASE_URL
  default_options.merge!({ timeout: 20 }.merge(httparty_ssl_options))

  def accounts_by_l1_address(address)
    get_json("/api/v1/accountsByL1Address", l1_address: address).fetch("sub_accounts", [])
  end

  def account_by_index(index)
    get_json("/api/v1/account", by: "index", value: index.to_s, active_only: false).fetch("accounts", []).first || {}
  end

  def total_account_value_for_l1_address(address)
    accounts = accounts_by_l1_address(address)

    detailed_accounts = accounts.filter_map do |account|
      index = account["index"] || account[:index]
      next if index.blank?

      details = account_by_index(index)
      {
        index: index.to_s,
        collateral: BigDecimal(details["collateral"].to_s),
        total_asset_value: BigDecimal(details["total_asset_value"].to_s),
        unrealized_pnl: Array(details["positions"]).sum { |position| BigDecimal(position["unrealized_pnl"].to_s) }
      }
    end

    {
      total_account_value: detailed_accounts.sum { |account| account[:total_asset_value] },
      total_collateral: detailed_accounts.sum { |account| account[:collateral] },
      total_unrealized_pnl: detailed_accounts.sum { |account| account[:unrealized_pnl] },
      accounts: detailed_accounts
    }
  end

  private

    def get_json(path, query = {})
      response = self.class.get(path, query: query)
      parsed = response.parsed_response

      raise Error, "Lighter request failed with status #{response.code}" unless response.success?
      raise Error, "Lighter response was not JSON" unless parsed.is_a?(Hash)

      parsed
    end
end
