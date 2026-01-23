# frozen_string_literal: true

module Admin
  class BaseController < ApplicationController
    before_action :require_super_admin!

    layout "settings"

    private
      def require_super_admin!
        unless Current.user&.super_admin?
          redirect_to root_path, alert: t("admin.unauthorized")
        end
      end
  end
end
