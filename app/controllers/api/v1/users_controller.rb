# frozen_string_literal: true

class Api::V1::UsersController < Api::V1::BaseController
  before_action :ensure_write_scope

  def reset
    FamilyResetJob.perform_later(Current.family)
    render json: { message: "Account reset has been initiated" }
  end

  def destroy
    user = current_resource_owner

    if user.deactivate
      Current.session&.destroy
      render json: { message: "Account has been deleted" }
    else
      render json: { error: "Failed to delete account", details: user.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end
end
