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

    # Active goals that AutoFundJob will actually fund: ones with a
    # positive monthly_target_amount. Goals without a target_date have
    # nil monthly_target and the job skips them, so a button gated on
    # active_goals.any? alone would queue a no-op for those families.
    def fundable_goals
      active_goals.select { |g| g.monthly_target_amount.to_d.positive? }
    end
  end
end
