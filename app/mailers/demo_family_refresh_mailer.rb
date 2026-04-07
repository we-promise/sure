class DemoFamilyRefreshMailer < ApplicationMailer
  def completed
    @super_admin = params.fetch(:super_admin)
    @old_family_id = params[:old_family_id]
    @old_family_name = params[:old_family_name]
    @old_family_session_count = params.fetch(:old_family_session_count)
    @newly_created_families_count = params.fetch(:newly_created_families_count)
    @period_start = params.fetch(:period_start)
    @period_end = params.fetch(:period_end)

    mail(
      to: @super_admin.email,
      subject: "Demo family refresh completed"
    )
  end
end
