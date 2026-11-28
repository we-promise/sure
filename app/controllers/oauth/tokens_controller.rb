class Oauth::TokensController < Doorkeeper::TokensController
  private

    # A password change takes the user row lock and revokes every token it
    # can see before committing. Doorkeeper does not lock anything on refresh
    # while refresh tokens are revoked on use (the previous_refresh_token
    # column), so a refresh that validated its token before the change could
    # still commit a successor after both revocation sweeps had run.
    #
    # Taking the same lock here, user before token as /api/v1/auth/refresh
    # does, makes every issuance from an existing credential land either
    # wholly before the password change (and get revoked by it) or wholly
    # after it (and find the credential already revoked).
    def authorize_response
      @authorize_response ||= with_resource_owner_lock { super }
    end

    def with_resource_owner_lock
      credential = presented_credential
      return yield unless credential&.resource_owner_id

      user = User.find_by(id: credential.resource_owner_id)
      raise Doorkeeper::Errors::InvalidGrantReuse unless user

      user.with_active_lock! do
        reload_under_lock(credential)
        yield
      end
    rescue User::InactiveError
      raise Doorkeeper::Errors::InvalidGrantReuse
    end

    # Grant types that redeem a credential bound to a user. Client
    # credentials and unknown grant types carry no user and fall through
    # to Doorkeeper unchanged.
    def presented_credential
      case strategy
      when Doorkeeper::Request::RefreshToken then strategy.request.refresh_token
      when Doorkeeper::Request::AuthorizationCode then strategy.request.grant
      end
    end

    # The credential was read before the lock was taken; Doorkeeper must
    # validate the row as it stands now that a password change can no
    # longer be in flight.
    def reload_under_lock(credential)
      credential.reload
    rescue ActiveRecord::RecordNotFound
      raise Doorkeeper::Errors::InvalidGrantReuse
    end
end
