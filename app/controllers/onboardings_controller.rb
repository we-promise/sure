class OnboardingsController < ApplicationController
  layout "wizard"

  before_action :set_user
  before_action :load_invitation

  def show
  end

  def preferences
  end

  def tools
  end

  def update_tools
    @user.save_onboarding_tools_and_ai(
      tools: tools_params[:onboarding_tools],
      other_tool: tools_params[:onboarding_other_tool],
      ai_mode: tools_params[:onboarding_ai_mode],
      rendered_ai_mode: tools_params[:rendered_ai_mode]
    )
    redirect_to self_hosted? ? root_path : trial_onboarding_path
  rescue ActiveRecord::RecordInvalid
    redirect_to tools_onboarding_path, alert: @user.errors.full_messages.to_sentence
  end

  def trial
  end

  private
    def tools_params
      params.fetch(:user, {}).permit(:onboarding_other_tool, :onboarding_ai_mode, :rendered_ai_mode, onboarding_tools: [])
    end

    def set_user
      @user = Current.user
    end

    def load_invitation
      @invitation = Current.family.invitations.accepted.find_by(email: Current.user.email)
    end
end
