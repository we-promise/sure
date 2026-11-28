class RematchCounterpartyAccountsJob < ApplicationJob
  queue_as :low_priority

  def perform(family)
    Account::CounterpartyRematcher.new(family).rematch!
  end
end
