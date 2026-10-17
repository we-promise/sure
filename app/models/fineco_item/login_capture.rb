class FinecoItem
  class LoginCapture
    IDENTITY_KEYS = %i[family_id user_id session_id].freeze
    DOSSIER_IDENTITY_PATTERN = /\A[a-f0-9]{64}\z/
    Cancelled = Class.new(StandardError)

    def initialize(expected_identity:, existing_item_id:, expected_connection_generation:)
      @expected_identity = expected_identity.to_h.with_indifferent_access.slice(*IDENTITY_KEYS).transform_values(&:to_s).freeze
      @existing_item_id = existing_item_id
      @expected_connection_generation = expected_connection_generation
    end

    def call(identity:, session:, cancelled: nil)
      Rails.application.executor.wrap do
        ActiveRecord::Base.connection_pool.with_connection do
          persist_capture(identity, session, cancelled)
        end
      end
    rescue Cancelled
      false
    rescue FinecoItem::PortfolioImportError
      raise
    rescue StandardError
      false
    end

    private

      def persist_capture(callback_identity, session, cancelled)
        unless Provider::Fineco.verified_identity_contract?
          raise FinecoItem::PortfolioImportError.new(:identity_verification_required)
        end

        return false unless capture_allowed?(callback_identity, cancelled)
        return false unless FinecoLoginAuthorization.explicitly_encrypted?

        captured = captured_session_attributes(session)
        return false unless captured

        item = find_capture_item
        return false unless item
        return false if @existing_item_id.nil? && item.persisted?

        result = Provider::Fineco.new(
          gsessionid: captured[:gsessionid],
          account_index: captured[:account_index],
          dossier_index: captured[:dossier_index]
        ).fetch_portfolio_summary

        return false unless capture_allowed?(callback_identity, cancelled)
        return false unless verified_bank_identity?(result)

        persist_verified_capture(item, captured, result, callback_identity, cancelled)
      end

      def persist_verified_capture(item, captured, result, callback_identity, cancelled)
        if @existing_item_id.nil? && capture_item_exists?
          return false
        end

        if item.persisted?
          persist_existing_item(item, captured, result, callback_identity, cancelled)
        else
          FinecoItem.transaction do
            persist_new_item(item, captured, result, callback_identity, cancelled)
          end
        end
      end

      def persist_existing_item(item, captured, result, callback_identity, cancelled)
        item.with_lock do
          return false unless capture_allowed?(callback_identity, cancelled)
          return false unless item.connection_generation == @expected_connection_generation
          return false unless item.same_bank_identity?(
            account_number: result.account_number,
            dossier_identity: result.dossier_identity
          )

          import_and_persist(item, captured, result, callback_identity, cancelled)
        end
        true
      end

      def persist_new_item(item, captured, result, callback_identity, cancelled)
        raise Cancelled unless capture_allowed?(callback_identity, cancelled)

        import_and_persist(item, captured, result, callback_identity, cancelled)
      end

      def import_and_persist(item, captured, result, callback_identity, cancelled)
        raise Cancelled unless capture_allowed?(callback_identity, cancelled)

        item.assign_attributes(
          gsessionid: result.rotated_gsessionid.presence || captured[:gsessionid],
          account_index: captured[:account_index],
          dossier_index: captured[:dossier_index],
          captured_at: captured[:captured_at],
          bank_account_number: result.account_number,
          dossier_identity: result.dossier_identity,
          connection_generation: item.connection_generation + 1,
          status: "good"
        )
        item.save!
        item.import_portfolio_snapshot!(
          payload: result.payload,
          captured_at: captured[:captured_at],
          allow_account_bootstrap: true
        )
        raise Cancelled unless capture_allowed?(callback_identity, cancelled)

        true
      end

      def matching_authorized_identity?(callback_identity)
        callback = callback_identity.to_h.with_indifferent_access

        FinecoLoginAuthorization.authorized?(callback) &&
          IDENTITY_KEYS.all? { |key| @expected_identity[key] == callback[key].to_s }
      rescue StandardError
        false
      end

      def capture_allowed?(callback_identity, cancelled)
        !cancellation_requested?(cancelled) && matching_authorized_identity?(callback_identity)
      end

      def cancellation_requested?(cancelled)
        cancelled.respond_to?(:call) && !!cancelled.call
      rescue StandardError
        true
      end

      def verified_bank_identity?(result)
        result.account_number.is_a?(String) && result.account_number.present? &&
          result.dossier_identity.is_a?(String) && result.dossier_identity.match?(DOSSIER_IDENTITY_PATTERN)
      end

      def captured_session_attributes(session)
        values = session.to_h.with_indifferent_access
        gsessionid = values[:gsessionid]
        account_index = values[:account_index]
        dossier_index = values[:dossier_index]
        captured_at = values[:captured_at]
        captured_at = Time.zone.parse(captured_at) if captured_at.is_a?(String)

        return unless [ gsessionid, account_index, dossier_index ].all? { |value| value.is_a?(String) && value.present? }
        return unless captured_at.respond_to?(:to_time)

        {
          gsessionid: gsessionid,
          account_index: account_index,
          dossier_index: dossier_index,
          captured_at: captured_at.to_time
        }
      rescue StandardError
        nil
      end

      def find_capture_item
        scope = capture_item_scope

        return scope.find_by(id: @existing_item_id) if @existing_item_id
        return if scope.exists?

        scope.build(
          family_id: @expected_identity[:family_id],
          owner_id: @expected_identity[:user_id]
        )
      end

      def capture_item_exists?
        capture_item_scope.exists?
      end

      def capture_item_scope
        FinecoItem.where(
          family_id: @expected_identity[:family_id],
          owner_id: @expected_identity[:user_id]
        )
      end
  end
end
