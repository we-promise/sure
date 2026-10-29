class WebPushSubscriptionsController < ApplicationController
  before_action :require_browser_push_preview
  before_action :require_web_push_configuration, only: [ :create, :test_notification ]
  before_action :set_subscription, only: [ :show, :destroy, :test_notification ]

  def create
    attributes = params.permit(:endpoint, :p256dh, :auth)
    subscription = WebPushSubscription.register_for!(user: Current.user, session: Current.session,
      endpoint: attributes[:endpoint], p256dh: attributes[:p256dh], auth: attributes[:auth])
    render json: { id: subscription.id }, status: :created
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    render json: { error: t("web_push.errors.registration") }, status: :unprocessable_entity
  end

  def show
    delivery = @subscription.web_push_deliveries.where(insight_id: nil).order(created_at: :desc).first
    render json: { id: @subscription.id, test_status: delivery&.status }
  end

  def destroy
    @subscription.destroy!
    head :no_content
  end

  def test_notification
    delivery = @subscription.with_lock do
      if @subscription.last_test_requested_at && @subscription.last_test_requested_at > 30.seconds.ago
        next nil
      end
      @subscription.update!(last_test_requested_at: Time.current)
      @subscription.web_push_deliveries.create!
    end
    return render json: { error: t("web_push.errors.rate_limited") }, status: :too_many_requests unless delivery

    if delivery.enqueue!
      render json: { status: "queued" }, status: :accepted
    else
      render json: { error: t("web_push.errors.enqueue") }, status: :service_unavailable
    end
  end

  private
    def require_browser_push_preview
      unless Current.user.preview_features_enabled? && Current.session.user_id == Current.user.id
        render json: { error: t("web_push.errors.preview") }, status: :forbidden
      end
    end

    def require_web_push_configuration
      render json: { error: t("web_push.errors.unconfigured") }, status: :service_unavailable unless WebPush::Client.configured?
    end

    def set_subscription
      @subscription = Current.user.web_push_subscriptions.where(session: Current.session).find(params[:id])
    end
end
