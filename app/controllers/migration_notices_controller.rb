class MigrationNoticesController < ApplicationController
  before_action :require_admin!

  # DELETE /migration_notices/:key — admin acknowledges an action-required
  # banner, hiding it from this family until a future migration re-registers
  # it under a new key.
  def destroy
    Current.family.dismiss_migration_notice!(params[:key])
    redirect_back fallback_location: root_path,
                  notice: t("migration_notices.dismissed")
  end
end
