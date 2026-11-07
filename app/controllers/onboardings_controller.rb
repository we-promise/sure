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

  def trial
  end

  def configure_provider
    unless OnboardingAiConfiguration.allowed_for?(Current.user)
      return render json: { status: "failed", error: "forbidden" }, status: :forbidden
    end

    attributes = params.require(:ai_configuration).permit(:provider, :api_key, :model)
    configuration = OnboardingAiConfiguration.new(family: Current.family, provider: attributes[:provider], api_key: attributes[:api_key], model: attributes[:model])
    if configuration.save
      render json: { status: "saved", provider: configuration.provider }
    else
      render json: { status: "failed", error: configuration.error }, status: :unprocessable_entity
    end
  end

  private
    def set_user
      @user = Current.user
    end

    def load_invitation
      @invitation = Current.family.invitations.accepted.find_by(email: Current.user.email)
    end
end
