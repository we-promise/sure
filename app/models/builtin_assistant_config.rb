# frozen_string_literal: true

class BuiltinAssistantConfig < ApplicationRecord
  belongs_to :family

  PREFERRED_AI_MODEL_MAX_LENGTH = 128
  OPENAI_URI_BASE_MAX_LENGTH = 512

  validates :preferred_ai_model, length: { maximum: PREFERRED_AI_MODEL_MAX_LENGTH }, allow_blank: true
  validates :openai_uri_base, length: { maximum: OPENAI_URI_BASE_MAX_LENGTH }, allow_blank: true
  validate :preferred_ai_model_required_when_custom_endpoint

  def custom_openai_endpoint?
    openai_uri_base.present?
  end

  private

    def preferred_ai_model_required_when_custom_endpoint
      return unless openai_uri_base.present? && preferred_ai_model.blank?

      errors.add(:preferred_ai_model, :blank)
    end
end
