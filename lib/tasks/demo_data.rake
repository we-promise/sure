namespace :demo_data do
  desc "Add Apple Card and family Apple Cash accounts to an existing local demo family"
  task financekit: :environment do
    raise "FinanceKit demo seeding is only available in development/test" unless Rails.env.local?

    family = if ENV["FAMILY_ID"].present?
      Family.find(ENV.fetch("FAMILY_ID"))
    else
      email = ENV.fetch("DEMO_EMAIL", Rails.application.config_for(:demo).fetch(:email))
      User.find_by!(email: email).family
    end
    item = Demo::FinancekitGenerator.new(family, seed: ENV.fetch("SEED", 42)).generate!
    puts "Apple Wallet demo ready: #{item.accounts.count} linked accounts."
  end

  desc "Load empty demo dataset (no financial data)"
  task empty: :environment do
    start = Time.now
    skip_clear = ENV.fetch("SKIP_CLEAR", "1") == "1"
    puts "🚀 Loading EMPTY demo data#{skip_clear ? ' (preserving existing data)' : ' (clearing existing data)'}…"

    Demo::Generator.new.generate_empty_data!(skip_clear: skip_clear)

    puts "✅ Done in #{(Time.now - start).round(2)}s"
  end

  desc "Load new-user demo dataset (family created but not onboarded)"
  task new_user: :environment do
    start = Time.now
    skip_clear = ENV.fetch("SKIP_CLEAR", "1") == "1"
    puts "🚀 Loading NEW-USER demo data#{skip_clear ? ' (preserving existing data)' : ' (clearing existing data)'}…"

    Demo::Generator.new.generate_new_user_data!(skip_clear: skip_clear)

    puts "✅ Done in #{(Time.now - start).round(2)}s"
  end

  desc "Load full realistic demo dataset"
  task default: :environment do
    start    = Time.now
    seed     = ENV.fetch("SEED", Random.new_seed)
    skip_clear = ENV.fetch("SKIP_CLEAR", "1") == "1"
    puts "🚀 Loading FULL demo data (seed=#{seed})#{skip_clear ? ' (preserving existing data)' : ' (clearing existing data)'}…"

    generator = Demo::Generator.new(seed: seed)
    generator.generate_default_data!(skip_clear: skip_clear)

    validate_demo_data

    elapsed = Time.now - start
    puts "🎉 Demo data ready in #{elapsed.round(2)}s"
  end

  # ---------------------------------------------------------------------------
  # Validation helpers
  # ---------------------------------------------------------------------------
  def validate_demo_data
    total_entries   = Entry.count
    trade_entries   = Entry.where(entryable_type: "Trade").count
    categorized_txn = Transaction.joins(:category).count
    txn_total       = Transaction.count

    coverage = ((categorized_txn.to_f / txn_total) * 100).round(1)

    puts "\n📊 Validation Summary".ljust(40, "-")
    puts "Entries total:              #{total_entries}"
    puts "Trade entries:             #{trade_entries} (#{trade_entries.between?(500, 1000) ? '✅' : '❌'})"
    puts "Txn categorization:        #{coverage}% (>=75% ✅)"

    unless total_entries.between?(8_000, 12_000)
      puts "Total entries #{total_entries} outside 8k–12k range"
    end

    unless trade_entries.between?(500, 1000)
      puts "Trade entries #{trade_entries} outside 500–1 000 range"
    end

    unless coverage >= 75
      puts "Categorization coverage below 75%"
    end
  end
end

# Alias namespace to avoid forgetfulness
namespace :sample_data do
  desc "Load full realistic demo dataset (alias for demo_data:default)"
  task default: "demo_data:default"
end
