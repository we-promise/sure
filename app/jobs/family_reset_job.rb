class FamilyResetJob < ApplicationJob
  queue_as :low_priority

  def perform(family, load_sample_data_for_email: nil)
    # report: false skips the before/after count queries - the Result is
    # discarded here, we only need the deletion side effects.
    Family::FinancialDataReset.new(
      family: family,
      dry_run: false,
      confirmed: true,
      report: false
    ).call

    if load_sample_data_for_email.present?
      Demo::Generator.new.generate_new_user_data_for!(family.reload, email: load_sample_data_for_email)
    else
      family.sync_later
    end
  end
end
