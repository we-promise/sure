# force_pkce only verifies a code_verifier when the grant can store the
# challenge; without these columns Doorkeeper refuses public clients outright.
class AddPkceColumnsToOauthAccessGrants < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_access_grants, :code_challenge, :string
    add_column :oauth_access_grants, :code_challenge_method, :string
  end
end
