# frozen_string_literal: true

# Helper module for sync stats rake tasks
module DevSyncStatsHelpers
  extend self

  def generate_fake_stats_for_items(item_class, provider_name, include_issues: false)
    items = item_class.all
    if items.empty?
      puts "  No #{item_class.name} items found, skipping..."
      return
    end

    items.each do |item|
      # Create or find a sync record
      sync = item.syncs.ordered.first
      if sync.nil?
        sync = item.syncs.create!(status: :completed, completed_at: Time.current)
      end

      stats = generate_fake_stats(provider_name, include_issues: include_issues)
      sync.update!(sync_stats: stats, status: :completed, completed_at: Time.current)

      item_name = item.respond_to?(:name) ? item.name : item.try(:institution_name) || item.id
      puts "  Generated stats for #{item_class.name} ##{item.id} (#{item_name})"
    end
  end

  def generate_fake_stats(provider_name, include_issues: false)
    # Base stats that all providers have
    stats = {
      "total_accounts" => rand(3..15),
      "linked_accounts" => rand(2..10),
      "unlinked_accounts" => rand(0..3),
      "import_started" => true,
      "window_start" => 1.hour.ago.iso8601,
      "window_end" => Time.current.iso8601
    }

    # Ensure linked + unlinked <= total
    stats["linked_accounts"] = [ stats["linked_accounts"], stats["total_accounts"] ].min
    stats["unlinked_accounts"] = stats["total_accounts"] - stats["linked_accounts"]

    # Add transaction stats for most providers
    unless provider_name == "coinstats"
      stats.merge!(
        "tx_seen" => rand(50..500),
        "tx_imported" => rand(10..100),
        "tx_updated" => rand(0..50),
        "tx_skipped" => rand(0..5)
      )
      # Ensure seen = imported + updated
      stats["tx_seen"] = stats["tx_imported"] + stats["tx_updated"]
    end

    # Add holdings stats for investment-capable providers
    if %w[simplefin plaid coinstats].include?(provider_name)
      stats["holdings_found"] = rand(5..50)
    end

    # Add issues if requested
    if include_issues
      # Random chance of rate limiting
      if rand < 0.3
        stats["rate_limited"] = true
        stats["rate_limited_at"] = rand(1..24).hours.ago.iso8601
      end

      # Random errors
      if rand < 0.4
        error_count = rand(1..3)
        stats["errors"] = error_count.times.map do
          {
            "message" => [
              "Connection timeout",
              "Invalid credentials",
              "Rate limit exceeded",
              "Temporary API error"
            ].sample,
            "category" => %w[api_error connection_error auth_error].sample
          }
        end
        stats["total_errors"] = error_count
      else
        stats["total_errors"] = 0
      end

      # Data quality warnings
      if rand < 0.5
        stats["data_warnings"] = rand(1..8)
        stats["notices"] = rand(0..3)
        stats["data_quality_details"] = stats["data_warnings"].times.map do |i|
          start_date = rand(30..180).days.ago.to_date
          end_date = start_date + rand(14..60).days
          gap_days = (end_date - start_date).to_i

          {
            "message" => "No transactions between #{start_date} and #{end_date} (#{gap_days} days)",
            "severity" => gap_days > 30 ? "warning" : "info"
          }
        end
      end
    else
      stats["total_errors"] = 0
    end

    stats
  end
end

namespace :dev do
  namespace :sync_stats do
    desc "Generate fake sync stats for testing the sync summary UI"
    task generate: :environment do
      unless Rails.env.development?
        puts "This task is only available in development mode"
        exit 1
      end

      puts "Generating fake sync stats for testing..."

      DevSyncStatsHelpers.generate_fake_stats_for_items(PlaidItem, "plaid")
      DevSyncStatsHelpers.generate_fake_stats_for_items(SimplefinItem, "simplefin")
      DevSyncStatsHelpers.generate_fake_stats_for_items(LunchflowItem, "lunchflow")
      DevSyncStatsHelpers.generate_fake_stats_for_items(EnableBankingItem, "enable_banking")
      DevSyncStatsHelpers.generate_fake_stats_for_items(CoinstatsItem, "coinstats")

      puts "Done! Refresh your browser to see the sync summaries."
    end

    desc "Clear all sync stats from syncs"
    task clear: :environment do
      unless Rails.env.development?
        puts "This task is only available in development mode"
        exit 1
      end

      puts "Clearing all sync stats..."
      Sync.where.not(sync_stats: nil).update_all(sync_stats: nil)
      puts "Done!"
    end

    desc "Generate fake sync stats with errors and warnings for testing"
    task generate_with_issues: :environment do
      unless Rails.env.development?
        puts "This task is only available in development mode"
        exit 1
      end

      puts "Generating fake sync stats with errors and warnings..."

      DevSyncStatsHelpers.generate_fake_stats_for_items(PlaidItem, "plaid", include_issues: true)
      DevSyncStatsHelpers.generate_fake_stats_for_items(SimplefinItem, "simplefin", include_issues: true)
      DevSyncStatsHelpers.generate_fake_stats_for_items(LunchflowItem, "lunchflow", include_issues: true)
      DevSyncStatsHelpers.generate_fake_stats_for_items(EnableBankingItem, "enable_banking", include_issues: true)
      DevSyncStatsHelpers.generate_fake_stats_for_items(CoinstatsItem, "coinstats", include_issues: true)

      puts "Done! Refresh your browser to see the sync summaries with issues."
    end

    desc "Create fake provider items with sync stats for testing (use when you have no provider connections)"
    task create_test_providers: :environment do
      unless Rails.env.development?
        puts "This task is only available in development mode"
        exit 1
      end

      family = Family.first
      unless family
        puts "No family found. Please create a user account first."
        exit 1
      end

      puts "Creating fake provider items for family: #{family.name || family.id}..."

      # Create a fake SimpleFIN item
      simplefin_item = family.simplefin_items.create!(
        name: "Test SimpleFIN Connection",
        access_url: "https://test.simplefin.org/fake"
      )
      puts "  Created SimplefinItem: #{simplefin_item.name}"

      # Create fake SimpleFIN accounts
      3.times do |i|
        simplefin_item.simplefin_accounts.create!(
          name: "Test Account #{i + 1}",
          account_id: "test-account-#{SecureRandom.hex(8)}",
          currency: "USD",
          current_balance: rand(1000..50000),
          account_type: %w[checking savings credit_card].sample
        )
      end
      puts "    Created 3 SimplefinAccounts"

      # Create a fake Plaid item (requires access_token)
      plaid_item = family.plaid_items.create!(
        name: "Test Plaid Connection",
        access_token: "test-access-token-#{SecureRandom.hex(16)}",
        plaid_id: "test-plaid-id-#{SecureRandom.hex(8)}"
      )
      puts "  Created PlaidItem: #{plaid_item.name}"

      # Create fake Plaid accounts
      2.times do |i|
        plaid_item.plaid_accounts.create!(
          name: "Test Plaid Account #{i + 1}",
          plaid_id: "test-plaid-account-#{SecureRandom.hex(8)}",
          currency: "USD",
          current_balance: rand(1000..50000),
          plaid_type: %w[depository credit investment].sample,
          plaid_subtype: "checking"
        )
      end
      puts "    Created 2 PlaidAccounts"

      # Create a fake Lunchflow item
      lunchflow_item = family.lunchflow_items.create!(
        name: "Test Lunchflow Connection",
        api_key: "test-api-key-#{SecureRandom.hex(16)}"
      )
      puts "  Created LunchflowItem: #{lunchflow_item.name}"

      # Create fake Lunchflow accounts
      2.times do |i|
        lunchflow_item.lunchflow_accounts.create!(
          name: "Test Lunchflow Account #{i + 1}",
          account_id: "test-lunchflow-#{SecureRandom.hex(8)}",
          currency: "USD",
          current_balance: rand(1000..50000)
        )
      end
      puts "    Created 2 LunchflowAccounts"

      # Create a fake CoinStats item
      coinstats_item = family.coinstats_items.create!(
        name: "Test CoinStats Connection",
        api_key: "test-coinstats-key-#{SecureRandom.hex(16)}",
        institution_name: "CoinStats"
      )
      puts "  Created CoinstatsItem: #{coinstats_item.name}"

      # Create fake CoinStats accounts (wallets)
      3.times do |i|
        coinstats_item.coinstats_accounts.create!(
          name: "Test Wallet #{i + 1}",
          account_id: "test-wallet-#{SecureRandom.hex(8)}",
          currency: "USD",
          current_balance: rand(100..10000),
          account_type: %w[wallet exchange defi].sample
        )
      end
      puts "    Created 3 CoinstatsAccounts"

      # Create a fake EnableBanking item
      begin
        enable_banking_item = family.enable_banking_items.create!(
          name: "Test EnableBanking Connection",
          institution_name: "Test Bank EU",
          institution_id: "test-bank-#{SecureRandom.hex(8)}",
          country_code: "DE",
          aspsp_name: "Test Bank",
          aspsp_id: "test-aspsp-#{SecureRandom.hex(8)}",
          application_id: "test-app-#{SecureRandom.hex(8)}",
          client_certificate: "-----BEGIN CERTIFICATE-----\nTEST_CERTIFICATE\n-----END CERTIFICATE-----"
        )
        puts "  Created EnableBankingItem: #{enable_banking_item.institution_name}"

        # Create fake EnableBanking accounts
        2.times do |i|
          uid = "test-eb-uid-#{SecureRandom.hex(8)}"
          enable_banking_item.enable_banking_accounts.create!(
            name: "Test EU Account #{i + 1}",
            uid: uid,
            account_id: "test-eb-account-#{SecureRandom.hex(8)}",
            currency: "EUR",
            current_balance: rand(1000..50000),
            iban: "DE#{rand(10..99)}#{SecureRandom.hex(10).upcase[0..17]}"
          )
        end
        puts "    Created 2 EnableBankingAccounts"
      rescue => e
        puts "  Failed to create EnableBankingItem: #{e.message}"
      end

      puts "\nNow generating sync stats for the test providers..."
      DevSyncStatsHelpers.generate_fake_stats_for_items(SimplefinItem, "simplefin", include_issues: true)
      DevSyncStatsHelpers.generate_fake_stats_for_items(PlaidItem, "plaid", include_issues: false)
      DevSyncStatsHelpers.generate_fake_stats_for_items(LunchflowItem, "lunchflow", include_issues: false)
      DevSyncStatsHelpers.generate_fake_stats_for_items(CoinstatsItem, "coinstats", include_issues: true)
      DevSyncStatsHelpers.generate_fake_stats_for_items(EnableBankingItem, "enable_banking", include_issues: false)

      puts "\nDone! Visit /accounts to see the sync summaries."
    end

    desc "Remove all test provider items created by create_test_providers"
    task remove_test_providers: :environment do
      unless Rails.env.development?
        puts "This task is only available in development mode"
        exit 1
      end

      puts "Removing test provider items..."

      # Remove items that start with "Test "
      count = 0
      count += SimplefinItem.where("name LIKE ?", "Test %").destroy_all.count
      count += PlaidItem.where("name LIKE ?", "Test %").destroy_all.count
      count += LunchflowItem.where("name LIKE ?", "Test %").destroy_all.count
      count += CoinstatsItem.where("name LIKE ?", "Test %").destroy_all.count
      count += EnableBankingItem.where("name LIKE ? OR institution_name LIKE ?", "Test %", "Test %").destroy_all.count

      puts "Removed #{count} test provider items. Done!"
    end
  end
end
