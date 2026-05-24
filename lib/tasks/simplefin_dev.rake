# Developer utilities for exercising the SimpleFIN setup/relink flows.
# Safe only against development/test databases — never run against production.

namespace :simplefin do
  desc "Seed a card-replacement (fraud) scenario for the user with the given email"
  task :seed_fraud_scenario, [ :user_email ] => :environment do |_t, args|
    if Rails.env.production?
      abort("Refusing to run simplefin:seed_fraud_scenario in production")
    end

    email = args[:user_email].presence ||
      ENV["USER_EMAIL"].presence ||
      abort("Usage: bin/rails 'simplefin:seed_fraud_scenario[user@example.com]'")

    user = User.find_by!(email: email)
    family = user.family
    puts "Seeding fraud scenario for #{user.email} (family: #{family.id})"

    # Piggyback on an existing SimpleFIN item when the family already has one,
    # so the seeded pair renders inside that card (matching how real fraud
    # replacements appear: both cards come from the same institution's item).
    # Fall back to a dedicated seed item otherwise.
    item = family.simplefin_items.where.not(name: "Dev Fraud Scenario").first
    if item
      puts "  Attaching to existing item: #{item.name} (#{item.id})"
    else
      item = family.simplefin_items.create!(
        name: "Dev Fraud Scenario",
        access_url: "https://example.com/seed/#{SecureRandom.hex(4)}"
      )
      puts "  Created standalone item: #{item.name} (#{item.id})"
    end

    old_sfa = item.simplefin_accounts.create!(
      name: "Citi Double Cash Card-OLD (9999)",
      account_id: "seed_citi_old_#{SecureRandom.hex(3)}",
      currency: "USD",
      account_type: "credit",
      current_balance: 0,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        {
          "id" => "seed_old_tx_1",
          "transacted_at" => 60.days.ago.to_i,
          "posted" => 60.days.ago.to_i,
          "amount" => "-42.50",
          "payee" => "Coffee Shop"
        }
      ]
    )

    sure_account = family.accounts.create!(
      name: "Citi Double Cash (dev seed)",
      balance: 0,
      currency: "USD",
      accountable: CreditCard.create!(subtype: "credit_card")
    )
    AccountProvider.create!(account: sure_account, provider: old_sfa)

    new_sfa = item.simplefin_accounts.create!(
      name: "Citi Double Cash Card-NEW (1111)",
      account_id: "seed_citi_new_#{SecureRandom.hex(3)}",
      currency: "USD",
      account_type: "credit",
      current_balance: -987.65,
      org_data: { "name" => "Citibank" },
      raw_transactions_payload: [
        { "id" => "seed_new_tx_1", "transacted_at" => 1.day.ago.to_i, "posted" => 1.day.ago.to_i, "amount" => "-24.50", "payee" => "Lunch" },
        { "id" => "seed_new_tx_2", "transacted_at" => 3.days.ago.to_i, "posted" => 3.days.ago.to_i, "amount" => "-120.00", "payee" => "Gas Station" }
      ]
    )

    # Simulate a recent sync so the prompt path fires (sync_stats holds the suggestion).
    suggestions = SimplefinItem::ReplacementDetector.new(item).call
    sync = item.syncs.create!(
      status: :completed,
      sync_stats: { "replacement_suggestions" => suggestions }
    )
    sync.update_column(:created_at, Time.current)

    puts "Created:"
    puts "  SimplefinItem:      #{item.id}"
    puts "  Dormant sfa (OLD):  #{old_sfa.id}"
    puts "  Active sfa (NEW):   #{new_sfa.id}"
    puts "  Sure account:       #{sure_account.id}"
    puts "  Suggestions:        #{suggestions.size}"
    puts
    puts "Next: load the accounts page in the dev server. You should see a"
    puts "replacement prompt on the 'Dev Fraud Scenario' SimpleFIN card."
    puts
    puts "To tear down: bin/rails 'simplefin:cleanup_fraud_scenario[#{email}]'"
  end

  desc "Remove all seeded fraud scenarios for the given user"
  task :cleanup_fraud_scenario, [ :user_email ] => :environment do |_t, args|
    if Rails.env.production?
      abort("Refusing to run simplefin:cleanup_fraud_scenario in production")
    end
    email = args[:user_email].presence ||
      ENV["USER_EMAIL"].presence ||
      abort("Usage: bin/rails 'simplefin:cleanup_fraud_scenario[user@example.com]'")

    user = User.find_by!(email: email)
    family = user.family
    # Drop seeded sfas by account_id prefix (see seed_* values in the seed task)
    # plus the Sure account created by the seed. This handles both the
    # standalone-item path and the piggyback-on-existing-item path.
    seed_sfas = SimplefinAccount
      .joins(:simplefin_item)
      .where(simplefin_items: { family_id: family.id })
      .where("account_id LIKE ?", "seed_citi_%")
    count_sfas = seed_sfas.count
    seed_sfas.find_each do |sfa|
      acct = sfa.current_account
      AccountProvider.where(provider: sfa).destroy_all
      acct&.destroy_later if acct&.may_mark_for_deletion?
      sfa.destroy
    end
    # Drop the seeded Sure account even when unlinked (name-based, safe).
    family.accounts.where(name: "Citi Double Cash (dev seed)").find_each do |acct|
      acct.destroy_later if acct.may_mark_for_deletion?
    end
    # Drop the standalone fallback item if it has no other sfas.
    family.simplefin_items.where(name: "Dev Fraud Scenario").find_each do |item|
      item.destroy if item.simplefin_accounts.reload.empty?
    end
    puts "Removed #{count_sfas} seeded sfa(s) for #{user.email}"
  end
end
