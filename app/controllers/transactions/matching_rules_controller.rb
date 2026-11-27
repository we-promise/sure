# The family's rules that match one transaction, for the drawer's lazy
# "Which rules match?" disclosure.
class Transactions::MatchingRulesController < ApplicationController
  def show
    @entry = Current.accessible_entries.transactions.find(params[:transaction_id])
    @matching_rules = Transaction::MatchingRules.new(@entry.transaction, rules: Current.family.rules)
  end
end
