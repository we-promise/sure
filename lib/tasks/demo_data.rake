namespace :demo_data do
  desc "Load empty demo dataset (no financial data)"
  task empty: :environment do
    start = Time.now
    puts "🚀 Loading EMPTY demo data…"

    Demo::Generator.new.generate_empty_data!

    puts "✅ Done in #{(Time.now - start).round(2)}s"
  end

  desc "Load new-user demo dataset (family created but not onboarded)"
  task new_user: :environment do
    start = Time.now
    puts "🚀 Loading NEW-USER demo data…"

    Demo::Generator.new.generate_new_user_data!

    puts "✅ Done in #{(Time.now - start).round(2)}s"
  end

  desc "Load full realistic demo dataset"
  task default: :environment do
    start    = Time.now
    seed     = ENV.fetch("SEED", Random.new_seed)
    append   = ActiveModel::Type::Boolean.new.cast(ENV["APPEND"])
    email    = ENV.fetch("EMAIL", "user@example.com")
    puts "🚀 Loading FULL demo data (seed=#{seed})…"

    generator = Demo::Generator.new(seed: seed)
    generator.generate_default_data!(skip_clear: append, email: email)

    validate_demo_data

    elapsed = Time.now - start
    puts "🎉 Demo data ready in #{elapsed.round(2)}s"
  end

  desc "Load Kenyan demo dataset (use APPEND=true to keep existing data)"
  task kenya: :environment do
    start    = Time.now
    seed     = ENV.fetch("SEED", Random.new_seed)
    append   = ENV.fetch("APPEND", "false").downcase == "true"

    if append
      puts "🚀 Loading KENYA demo data in APPEND mode (keeping existing data, seed=#{seed})…"
    else
      puts "🚀 Loading KENYA demo data (seed=#{seed})…"
    end

    generator = Demo::Generator.new(seed: seed)
    generator.generate_kenya_data!(skip_clear: append)

    validate_demo_data

    elapsed = Time.now - start
    puts "🎉 Kenyan demo data ready in #{elapsed.round(2)}s"
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
