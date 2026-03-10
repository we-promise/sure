class OnboardingsController < ApplicationController
  layout "wizard"

  before_action :set_user
  before_action :set_joined_existing_family

  def show
  end

  def preferences
  end

  def trial
  end

  private
    def set_user
      @user = Current.user
    end

    def set_joined_existing_family
      @invitation = Current.family.invitations.accepted.find_by(email: Current.user.email)
      @joined_existing_family = @invitation.present? || assigned_to_invite_only_family?
    end

    def assigned_to_invite_only_family?
      Setting.onboarding_state == "invite_only" &&
        Setting.invite_only_default_family_id.present? &&
        Setting.invite_only_default_family_id == Current.family.id.to_s
    end
end
