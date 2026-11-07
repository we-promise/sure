class Settings::AiPromptsController < ApplicationController
  layout "settings"

  before_action :require_admin!

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.ai_prompts"), nil ]
    ]
    @family ||= Current.family
  end

  def update
    Current.family.update!(prompt_params)

    redirect_to settings_ai_prompts_path, notice: t(".success")
  rescue ActiveRecord::RecordInvalid => e
    # Re-render rather than redirect so a rejected edit doesn't discard what the
    # admin typed into a multi-thousand-character textarea.
    flash.now[:alert] = error_message_for(e.record)
    @family = e.record
    show
    render :show, status: :unprocessable_entity
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
    def error_message_for(record)
      if record.errors.size > 1
        t(".multiple_errors", count: Family::AiPromptable::MAX_LENGTH.to_fs(:delimited))
      else
        record.errors.full_messages.first
      end
    end

    def prompt_params
      params.require(:family).permit(*Family::AiPromptable::FIELDS)
    end
end
