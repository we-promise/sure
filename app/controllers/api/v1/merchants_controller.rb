# frozen_string_literal: true

# app/controllers/api/v1/merchants_controller.rb
# API v1 endpoint for merchants
# Allows listing and viewing merchants (family + provider)

module Api
  module V1
    class MerchantsController < BaseController
      before_action :ensure_read_scope

      # GET /api/v1/merchants
      # Returns all merchants available to the family
      def index
        family = current_resource_owner.family

        # Get family merchants and provider merchants assigned to transactions
        family_merchants = family.merchants.alphabetically
        provider_merchants = Merchant.where(
          id: family.transactions.select(:merchant_id)
        ).where(type: "ProviderMerchant").alphabetically

        @merchants = (family_merchants + provider_merchants).uniq(&:id).sort_by(&:name)

        render json: @merchants.map { |m| merchant_json(m) }
      rescue StandardError => e
        Rails.logger.error("API Merchants Error: #{e.message}")
        render json: { error: "Failed to fetch merchants" }, status: :internal_server_error
      end

      # GET /api/v1/merchants/:id
      def show
        family = current_resource_owner.family

        @merchant = family.merchants.find_by(id: params[:id]) ||
                    Merchant.joins(:transactions)
                            .where(transactions: { account_id: family.accounts.select(:id) })
                            .find_by(id: params[:id])

        if @merchant
          render json: merchant_json(@merchant)
        else
          render json: { error: "Merchant not found" }, status: :not_found
        end
      rescue StandardError => e
        Rails.logger.error("API Merchant Show Error: #{e.message}")
        render json: { error: "Failed to fetch merchant" }, status: :internal_server_error
      end

      private

        def merchant_json(merchant)
          {
            id: merchant.id,
            name: merchant.name,
            type: merchant.type,
            created_at: merchant.created_at,
            updated_at: merchant.updated_at
          }
        end
    end
  end
end
