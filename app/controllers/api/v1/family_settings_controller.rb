# frozen_string_literal: true

class Api::V1::FamilySettingsController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    @family = current_resource_owner.family
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end
end
