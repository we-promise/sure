# frozen_string_literal: true

class Api::V1::PushSubscriptionsController < Api::V1::BaseController
  before_action :ensure_write_scope

  def create
    subscription = PushSubscription.register_for!(user: current_resource_owner,
      token: subscription_params[:token].to_s.downcase,
      environment: subscription_params[:environment], platform: subscription_params[:platform],
      device_key: subscription_params[:device_key])
    render json: serialize(subscription), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "validation_error", message: e.record.errors.full_messages.to_sentence },
           status: :unprocessable_entity
  rescue ActiveRecord::RecordNotUnique
    render json: { error: "validation_error", message: "Device token is already registered" },
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
      params.permit(:token, :environment, :platform, :device_key)
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
