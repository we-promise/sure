class Settings::ProfilesController < ApplicationController
  layout :layout_for_settings_profile

  def show
    @user = Current.user
    @users = Current.family.users.order(:created_at)
    @pending_invitations = Current.family.invitations.pending
    @breadcrumbs = [
      [ "Home", root_path ],
      [ "Profile Info", nil ]
    ]
  end

  def destroy
    unless Current.user.admin?
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

    # Check if user has a preserved family from a previous invitation
    # Pattern: email+family123@domain.com
    base_email = @user.email
    base_local, _, base_domain = base_email.partition('@')
    
    # Search for preserved user with email pattern: localpart+family*@domain
    # Use ILIKE for case-insensitive search on unencrypted email
    preserved_user = User.where("email ILIKE ?", "#{base_local}+family%@#{base_domain}").first
    
    if preserved_user && preserved_user.family_id != Current.family.id
      # Restore user to their preserved family
      @user.update!(family_id: preserved_user.family_id, role: preserved_user.role)
      preserved_user.destroy
      flash[:notice] = "Member removed and restored to their previous household."
    elsif @user.destroy
      # Also destroy the invitation associated with this user for this family
      Current.family.invitations.find_by(email: @user.email)&.destroy
      flash[:notice] = "Member removed successfully."
    else
      flash[:alert] = "Failed to remove member."
    end

    redirect_to settings_profile_path
  end

  private

    def layout_for_settings_profile
      Current.user&.ui_layout_intro? ? "application" : "settings"
    end
end
