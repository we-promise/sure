# The addresses and plus tags that tell the order mailbox whose an email is.
class Settings::PurchaseInboxRoutesController < ApplicationController
  guard_feature unless: -> { self_hosted? }
  before_action :require_preview_features!
  before_action :ensure_instance_settings_manager

  def create
    user = manageable_users.find(route_params[:user_id])
    route = user.purchase_inbox_routes.new(kind: route_params[:kind], value: route_params[:value])
    route.value = default_tag_for(user) if route.tag? && route.value.blank?

    if route.save
      redirect_to settings_purchase_inbox_path, notice: t(".added")
    else
      redirect_to settings_purchase_inbox_path, alert: route.errors.full_messages.to_sentence
    end
  end

  def destroy
    PurchaseInboxRoute.where(user: manageable_users).find(params[:id]).destroy!
    redirect_to settings_purchase_inbox_path, notice: t(".removed")
  end

  private
    def route_params
      params.require(:purchase_inbox_route).permit(:user_id, :kind, :value)
    end

    def manageable_users
      Current.user.super_admin? ? User.all : Current.family.users
    end

    # A shop can be told to send its emails to any address, so the tag mustn't be guessable from
    # the user's name alone.
    def default_tag_for(user)
      base = user.first_name.to_s.parameterize(separator: "").first(16).presence || "user"
      "#{base}-#{SecureRandom.alphanumeric(8).downcase}"
    end

    def ensure_instance_settings_manager
      return if Current.user.admin? && Current.user.manages_instance_settings?

      redirect_to settings_profile_path, alert: t("settings.purchase_inboxes.not_authorized")
    end
end
