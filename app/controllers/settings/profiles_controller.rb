class Settings::ProfilesController < ApplicationController
  layout :layout_for_settings_profile

  def show
    @user = Current.user
    @memberships = Current.family.family_memberships.includes(:user).order(created_at: :asc)
    @pending_invitations = Current.family.invitations.pending
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.profile"), nil ]
    ]
  end

  def destroy
    unless Current.user.admin?
      flash[:alert] = t("settings.profiles.destroy.not_authorized")
      redirect_to settings_profile_path
      return
    end

    membership = Current.family.family_memberships.find(params[:membership_id])
    @user = membership.user

    if @user == Current.user
      flash[:alert] = t("settings.profiles.destroy.cannot_remove_self")
      redirect_to settings_profile_path
      return
    end

    if @user.owned_accounts.where(family_id: Current.family.id).exists?
      flash[:alert] = t("settings.profiles.destroy.member_owns_household_data")
      redirect_to settings_profile_path
      return
    end

    if membership.destroy
      # Also destroy the invitation associated with this user for this family
      Current.family.invitations.find_by(email: @user.email)&.destroy
      flash[:notice] = t("settings.profiles.destroy.member_removed")
    else
      flash[:alert] = t("settings.profiles.destroy.member_removal_failed")
    end

    redirect_to settings_profile_path
  end

  private

    def layout_for_settings_profile
      Current.user&.ui_layout_intro? ? "application" : "settings"
    end
end
