# frozen_string_literal: true

module Api
  module V1
    class MerchantsController < BaseController
      before_action -> { authorize_scope!(:read) }, only: %i[index show]
      before_action -> { authorize_scope!(:read_write) }, only: %i[create update destroy]
      before_action :set_merchant, only: %i[show update destroy]
      before_action :ensure_family_merchant, only: %i[update destroy]

      def index
        family = current_resource_owner.family
        user = current_resource_owner

        family_merchant_ids = family.merchants.select(:id)
        accessible_account_ids = family.accounts.accessible_by(user).select(:id)
        provider_merchant_ids = Transaction.joins(:entry)
          .where(entries: { account_id: accessible_account_ids })
          .where.not(merchant_id: nil)
          .select(:merchant_id)

        @merchants = Merchant
          .where(id: family_merchant_ids)
          .or(Merchant.where(id: provider_merchant_ids, type: "ProviderMerchant"))
          .distinct
          .alphabetically

        render json: @merchants.map { |m| merchant_json(m) }
      rescue StandardError => e
        Rails.logger.error("API Merchants Error: #{e.message}")
        render json: { error: "Failed to fetch merchants" }, status: :internal_server_error
      end

      def show
        render json: merchant_json(@merchant)
      end

      def create
        family = current_resource_owner.family
        @merchant = family.merchants.new(merchant_params)

        if @merchant.save
          render json: merchant_json(@merchant), status: :created
        else
          render json: { error: @merchant.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("API Merchant Create Error: #{e.message}")
        render json: { error: "Failed to create merchant" }, status: :internal_server_error
      end

      def update
        if @merchant.update(merchant_params)
          render json: merchant_json(@merchant)
        else
          render json: { error: @merchant.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("API Merchant Update Error: #{e.message}")
        render json: { error: "Failed to update merchant" }, status: :internal_server_error
      end

      def destroy
        @merchant.destroy!
        head :no_content
      rescue StandardError => e
        Rails.logger.error("API Merchant Destroy Error: #{e.message}")
        render json: { error: "Failed to delete merchant" }, status: :internal_server_error
      end

      private

        def set_merchant
          family = current_resource_owner.family
          user = current_resource_owner

          @merchant = family.merchants.find_by(id: params[:id]) ||
                      Merchant.joins(transactions: :entry)
                              .where(entries: { account_id: family.accounts.accessible_by(user).select(:id) })
                              .where(type: "ProviderMerchant")
                              .distinct
                              .find_by(id: params[:id])

          unless @merchant
            render json: { error: "Merchant not found" }, status: :not_found
          end
        end

        def ensure_family_merchant
          return unless @merchant

          unless @merchant.is_a?(FamilyMerchant)
            render json: { error: "Provider merchants cannot be modified" }, status: :unprocessable_entity
          end
        end

        def merchant_params
          params.require(:merchant).permit(:name, :color, :website_url)
        end

        def merchant_json(merchant)
          {
            id: merchant.id,
            name: merchant.name,
            type: merchant.type,
            color: merchant.color,
            website_url: merchant.try(:website_url),
            created_at: merchant.created_at,
            updated_at: merchant.updated_at
          }
        end
    end
  end
end
