# frozen_string_literal: true

class Api::V1::PushSubscriptionsController < Api::V1::BaseController
  before_action :ensure_write_scope

  def create
    subscription = PushSubscription.find_or_initialize_by(token: subscription_params[:token])
    subscription.assign_attributes(
      user: current_resource_owner,
      environment: subscription_params[:environment],
      platform: subscription_params[:platform],
      last_registered_at: Time.current
    )
    subscription.save!

    render json: serialize(subscription), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "validation_error", message: e.record.errors.full_messages.to_sentence },
           status: :unprocessable_entity
  end

  def destroy
    current_resource_owner.push_subscriptions.find(params[:id]).destroy!
    head :no_content
  end

  private
    def ensure_write_scope
      authorize_scope!(:write)
    end

    def subscription_params
      params.permit(:token, :environment, :platform)
    end

    def serialize(subscription)
      {
        id: subscription.id,
        environment: subscription.environment,
        platform: subscription.platform,
        last_registered_at: subscription.last_registered_at.iso8601
      }
    end
end
