module ScalableTestHelper
  def scalable_credentials(person: "synthetic-person", refresh: "synthetic-refresh", key: "synthetic-private-key")
    { "access_token" => "synthetic-access", "refresh_token" => refresh, "private_key_pem" => key,
      "person_id" => person, "expires_at" => 1.hour.from_now.utc.iso8601 }
  end

  def scalable_owner
    owner = users(:family_admin)
    owner.update!(preferences: (owner.preferences || {}).merge("preview_features_enabled" => true))
    owner
  end

  def scalable_connected_item(owner: scalable_owner)
    ScalableItem.create!(family: owner.family, owner: owner, credentials: JSON.generate(scalable_credentials),
      person_identity: "synthetic-person", status: :connected, connection_generation: 1)
  end

  def scalable_pending_state
    { "phase" => "device", "verification_url" => "https://secure.scalable.capital/activate",
      "user_code" => "ABCD-EFGH", "device_code" => "synthetic-device-secret", "private_key_pem" => "synthetic-private-key",
      "expires_at" => 10.minutes.from_now.utc.iso8601, "poll_interval" => 5 }
  end
end
