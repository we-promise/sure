# frozen_string_literal: true

module Api
  module V1
    # API v1 endpoint for merchants
    # Provides read access to family and provider merchants,
    # and write access to create family merchants
    #
    # @example List all merchants
    #   GET /api/v1/merchants
    #
    # @example Get a specific merchant
    #   GET /api/v1/merchants/:id
    #
    # @example Create a new merchant
    #   POST /api/v1/merchants
    #   { "merchant": { "name": "Acme Corp", "color": "#e99537", "website_url": "https://acme.com" } }
    #
    class MerchantsController < BaseController
      before_action -> { authorize_scope!(:read) }, only: %i[index show]
      before_action -> { authorize_scope!(:read_write) }, only: %i[create]

      # List all merchants available to the family
      #
      # Returns both family-owned merchants and provider merchants
      # that are assigned to the family's transactions.
      #
      # @return [Array<Hash>] JSON array of merchant objects
      def index
        family = current_resource_owner.family

        # Single query with OR conditions - more efficient than Ruby deduplication
        family_merchant_ids = family.merchants.select(:id)
        provider_merchant_ids = family.transactions.select(:merchant_id)

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

      # Get a specific merchant by ID
      #
      # Returns a merchant if it belongs to the family or is assigned
      # to any of the family's transactions.
      #
      # @param id [String] The merchant ID
      # @return [Hash] JSON merchant object or error
      def show
        family = current_resource_owner.family

        @merchant = family.merchants.find_by(id: params[:id]) ||
                    Merchant.joins(transactions: :entry)
                            .where(entries: { account_id: family.accounts.select(:id) })
                            .distinct
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

      # Create a new family merchant
      #
      # @param name [String] Merchant name (required)
      # @param color [String] Hex color code (optional, auto-assigned if not provided)
      # @param website_url [String] Merchant website URL (optional)
      # @return [Hash] JSON merchant object with status 201
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

      private

        # Strong parameters for merchant creation
        #
        # @return [ActionController::Parameters] Permitted parameters
        def merchant_params
          params.require(:merchant).permit(:name, :color, :website_url)
        end

        # Serialize a merchant to JSON format
        #
        # @param merchant [Merchant] The merchant to serialize
        # @return [Hash] JSON-serializable hash
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
