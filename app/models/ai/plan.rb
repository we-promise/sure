# What may run for a feature: its lane and the ordered routes this family and user may use
# (`routes`, in order).
Ai::Plan = Data.define(:feature, :lane, :routes) do
  def route = routes.first

  def model = route.model
end
