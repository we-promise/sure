class ImpersonationSessionLog < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :ip_address
    encrypts :user_agent
  end

  belongs_to :impersonation_session
end
