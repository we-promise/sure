# frozen_string_literal: true

class Api::V1::UsersController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :reset_status
  before_action :ensure_write_scope, except: :reset_status
  before_action :ensure_admin, only: %i[reset reset_status]

  def reset
    family = current_resource_owner.family
    begin
      job = FamilyResetJob.perform_later(family)
    rescue StandardError => e
      Rails.logger.error "Failed to enqueue FamilyResetJob for family #{family.id}: #{e.message}"

      render json: {
        error: "reset_enqueue_failed",
        message: "Account reset could not be queued"
      }, status: :internal_server_error
      return
    end

    render json: {
      message: "Account reset has been initiated",
      status: "queued",
      job_id: job.job_id,
      family_id: family.id,
      status_url: api_v1_users_reset_status_path
    }
  end

  def reset_status
    family = current_resource_owner.family
    counts = reset_target_counts(family)
    reset_complete = counts.values.sum.zero?

    render json: {
      status: reset_complete ? "complete" : "data_remaining",
      family_id: family.id,
      reset_complete: reset_complete,
      counts: counts
    }
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

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_admin
      return true if current_resource_owner&.admin?

      render_json({ error: "forbidden", message: "You are not authorized to perform this action" }, status: :forbidden)
      false
    end

    def reset_target_counts(family)
      {
        accounts: family.accounts.count,
        categories: family.categories.count,
        tags: family.tags.count,
        merchants: family.merchants.count,
        plaid_items: family.plaid_items.count,
        imports: family.imports.count,
        budgets: family.budgets.count
      }
    end
end
