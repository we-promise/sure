class AddIssuerToOidcIdentities < ActiveRecord::Migration[7.2]
  def change
    add_column :oidc_identities, :issuer, :string
    add_index :oidc_identities, :issuer
  end
end
