class Family
  SavingsSummary = Data.define(
    :surplus,
    :allocated,
    :available,
    :active_goals,
    :currency
  ) do
    def surplus_money
      Money.new(surplus, currency)
    end

    def allocated_money
      Money.new(allocated, currency)
    end

    def available_money
      Money.new(available, currency)
    end
  end
end
