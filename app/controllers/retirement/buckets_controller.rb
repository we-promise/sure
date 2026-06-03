class Retirement::BucketsController < ApplicationController
  include RetirementScoped

  # Replace-all: the form submits the full set of selected account ids.
  def update
    requested = Array(params.dig(:bucket, :account_ids)).reject(&:blank?)
    # accessible_by, not just family-scoped: a private account shared away
    # from this user must not be addable to their bucket via a crafted POST.
    valid_ids = Current.family.accounts.accessible_by(Current.user).where(id: requested).pluck(:id)

    @plan.transaction do
      @plan.retirement_bucket_entries.where.not(account_id: valid_ids).destroy_all
      existing = @plan.retirement_bucket_entries.pluck(:account_id)
      (valid_ids - existing).each { |account_id| @plan.retirement_bucket_entries.create!(account_id: account_id) }
    end

    redirect_to retirement_path, notice: t(".updated")
  end
end
