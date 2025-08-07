class Provider::Simplefin::Demo
  # Demo setup token from SimpleFin documentation
  DEMO_TOKEN = "aHR0cHM6Ly9icmlkZ2Uuc2ltcGxlZmluLm9yZy9zaW1wbGVmaW4vY2xhaW0vZGVtbw=="

  def self.test_connection
    provider = Provider::Simplefin.new

    begin
      # Claim the demo token
      access_url = provider.claim_access_url(DEMO_TOKEN)
      puts "✓ Successfully claimed access URL: #{access_url[0..50]}..."

      # Get account data
      accounts_data = provider.get_accounts(access_url)
      puts "✓ Successfully retrieved accounts data"
      puts "  - Accounts count: #{accounts_data[:accounts]&.count || 0}"
      puts "  - Errors: #{accounts_data[:errors] || 'None'}"

      if accounts_data[:accounts]&.any?
        account = accounts_data[:accounts].first
        puts "  - First account: #{account[:name]} (#{account[:currency]}) - Balance: #{account[:balance]}"
        puts "  - Transactions: #{account[:transactions]&.count || 0}"
      end

      true
    rescue Provider::Simplefin::SimplefinError => e
      puts "✗ SimpleFin error: #{e.message} (#{e.error_type})"
      false
    rescue => e
      puts "✗ Unexpected error: #{e.message}"
      false
    end
  end
end
