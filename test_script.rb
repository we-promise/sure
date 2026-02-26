family = Family.first
account = family.accounts.create!(name: "ExcludeTest", balance: 0, currency: "USD", accountable: Depository.new, excluded: true)
entry = account.entries.create!(name: "TestTxn", amount: 100, currency: "USD", date: Date.current, entryable: Transaction.new)
search = Transaction::Search.new(family, filters: { "account_ids" => [account.id.to_s] })
puts "Search totals count is: #{search.totals.count}"
