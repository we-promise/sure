desc "Import Scalable Capital positions as trades into the first family's investment account"
task import_scalable: :environment do
  family = Family.order(:created_at).first
  abort "No family found" unless family

  puts "Using family: #{family.name} (#{family.id})"

  # Find or create the Scalable Capital account
  account = family.accounts.find_by(name: "Scalable Capital")

  unless account
    account = family.accounts.create!(
      accountable: Investment.new(subtype: "brokerage"),
      name: "Scalable Capital",
      balance: 0,
      currency: "EUR"
    )
    puts "Created account: Scalable Capital (#{account.id})"
  else
    puts "Found existing account: Scalable Capital (#{account.id})"
  end

  # Position data from Scalable Capital statement
  positions = [
    { ticker: "MSFT",  mic: "XNAS", name: "Microsoft",                            qty: 1.9844,   value: 668.64  },
    { ticker: "NVDA",  mic: "XNAS", name: "NVIDIA",                               qty: 5.7926,   value: 931.33  },
    { ticker: "AAPL",  mic: "XNAS", name: "Apple",                                qty: 3.9948,   value: 896.83  },
    { ticker: "GOOGL", mic: "XNAS", name: "Alphabet A",                           qty: 4.1326,   value: 1105.47 },
    { ticker: "MAIN",  mic: "XNYS", name: "Main Street Capital",                  qty: 27.4588,  value: 1363.33 },
    { ticker: "TSLA",  mic: "XNAS", name: "Tesla",                                qty: 2.5669,   value: 894.69  },
    { ticker: "CL2",   mic: "XPAR", name: "Amundi MSCI USA Daily 2x Leveraged",   qty: 144.1675, value: 3596.98 },
    { ticker: "3LQQ",  mic: "XLON", name: "WisdomTree NASDAQ 100 5x Leveraged",   qty: 54.1443,  value: 1558.27 },
    { ticker: "QQQ5",  mic: "XAMS", name: "Leverage Shares 5x Long Nasdaq 100",   qty: 146.5201, value: 197.80  },
  ]

  today = Date.current
  created = 0

  ActiveRecord::Base.transaction do
    positions.each do |pos|
      # Find or create security
      security = Security.find_or_create_by!(ticker: pos[:ticker], exchange_operating_mic: pos[:mic]) do |s|
        s.name = pos[:name]
        s.country_code = "US"
      end

      price = (pos[:value] / pos[:qty]).round(4)

      # Skip if a trade for this security already exists on this date
      existing = account.entries.joins("INNER JOIN trades ON trades.id = entries.entryable_id AND entries.entryable_type = 'Trade'")
                        .where(trades: { security_id: security.id })
                        .where(date: today)
                        .exists?

      if existing
        puts "  SKIP #{pos[:ticker]} — trade already exists for today"
        next
      end

      account.entries.create!(
        entryable: Trade.new(
          security: security,
          qty: pos[:qty],
          price: price,
          currency: "EUR"
        ),
        amount: -pos[:value],
        name: "Buy #{pos[:qty]} #{pos[:ticker]}",
        currency: "EUR",
        date: today
      )

      created += 1
      puts "  OK   #{pos[:ticker]}: #{pos[:qty]} × #{price} EUR = #{pos[:value]} EUR"
    end
  end

  puts "\nCreated #{created} trades. Triggering sync..."

  sync = Sync.create!(syncable: account)
  sync.perform

  account.reload
  puts "Account balance: #{account.balance} #{account.currency}"
  puts "Holdings: #{account.holdings.where(date: today).count}"
  puts "Done!"
end
