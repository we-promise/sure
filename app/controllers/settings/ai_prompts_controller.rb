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
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    @family = e.record
    show
    render :show, status: :unprocessable_entity
  end

  private
    def prompt_params
      params.require(:family).permit(*Family::AiPromptable::FIELDS)
    end
end
