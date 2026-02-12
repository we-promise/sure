class Settings::ProfilesController < ApplicationController
  layout :layout_for_settings_profile

  def show
    @user = Current.user
    @users = Current.family.users.order(:created_at)
    @memberships_by_user = Current.family.memberships.index_by(&:user_id)
    @pending_invitations = Current.family.invitations.pending
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Profile Info", nil ]
    ]
  end

  def destroy
    unless Current.admin?
      flash[:alert] = t("settings.profiles.destroy.not_authorized")
      redirect_to settings_profile_path
      return
    end

    @user = Current.family.users.find(params[:user_id])

    if @user == Current.user
      flash[:alert] = t("settings.profiles.destroy.cannot_remove_self")
      redirect_to settings_profile_path
      return
    end

    membership = @user.membership_for(Current.family)

    if membership&.destroy
      Current.family.invitations.find_by(email: @user.email)&.destroy
      @user.purge_later if @user.memberships.reload.empty?
      flash[:notice] = t("settings.profiles.destroy.success", default: "Member removed successfully.")
    else
      flash[:alert] = t("settings.profiles.destroy.failure", default: "Failed to remove member.")
    end

    redirect_to settings_profile_path
  end

  private

    def layout_for_settings_profile
      Current.user&.ui_layout_intro? ? "application" : "settings"
    end
end
