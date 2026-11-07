# What may run for a feature: its lane and the ordered routes this family and user may use
# (section 5.3). Failover and escalation (2c) move down `routes`.
Ai::Plan = Data.define(:feature, :lane, :routes) do
  def available? = true

  def route = routes.first

  def model = route.model
end
