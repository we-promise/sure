class InvitationsController < ApplicationController
  skip_authentication only: :accept
  def new
    @invitation = Invitation.new
  end

  def create
    unless Current.user.admin?
      flash[:alert] = t(".failure")
      redirect_to settings_profile_path
      return
    end

    @invitation = Current.family.invitations.build(invitation_params)
    @invitation.inviter = Current.user

    if @invitation.save
      normalized_email = @invitation.email.to_s.strip.downcase
      existing_user = User.find_by(email: normalized_email)
      
      # Check if user belongs to a different family before accepting
      user_has_different_family = existing_user && 
                                    existing_user.family_id != Current.family.id
      
      if existing_user && @invitation.accept_for(existing_user)
        if user_has_different_family
          flash[:notice] = t(".existing_user_added_with_warning")
        else
          flash[:notice] = t(".existing_user_added")
        end
      elsif existing_user
        flash[:alert] = t(".failure")
      else
        InvitationMailer.invite_email(@invitation).deliver_later unless self_hosted?
        flash[:notice] = t(".success")
      end
    else
      flash[:alert] = t(".failure")
    end

    redirect_to settings_profile_path
  end

  def accept
    @invitation = Invitation.find_by!(token: params[:id])

    if @invitation.pending?
      render :accept_choice, layout: "auth"
    else
      raise ActiveRecord::RecordNotFound
    end
  end

  def destroy
    unless Current.user.admin?
      flash[:alert] = t("invitations.destroy.not_authorized")
      redirect_to settings_profile_path
      return
    end

    @invitation = Current.family.invitations.find(params[:id])

    if @invitation.destroy
      flash[:notice] = t("invitations.destroy.success")
    else
      flash[:alert] = t("invitations.destroy.failure")
    end

    redirect_to settings_profile_path
  end

  private

    def invitation_params
      params.require(:invitation).permit(:email, :role)
    end
end
