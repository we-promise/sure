class Goals::AccountStackComponent < ApplicationComponent
  def initialize(accounts:, max: 3)
    @accounts = accounts
    @max = max
  end

  def shown
    @accounts.first(@max)
  end

  def extra_count
    [ @accounts.size - @max, 0 ].max
  end

  def initial_for(account)
    account.name.to_s.strip.first&.upcase || "?"
  end
end
