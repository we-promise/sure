class Transactions::UpcomingsController < ApplicationController
  layout false

  def show
    @projected_recurring = Current.family.recurring_transactions
                                  .accessible_by(Current.user)
                                  .active
                                  .where("next_expected_date <= ? AND next_expected_date >= ?",
                                         10.days.from_now.to_date,
                                         Date.current)
                                  .includes(:merchant)
  end
end
