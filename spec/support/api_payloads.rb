# Payloads shaped like the ones the Hetzner Cloud API returns.
#
# Only the fields the driver actually reads are filled in. A fixture that
# mirrors every field Hetzner sends invites specs that assert on data the
# driver never looks at, and has to be maintained when Hetzner adds a field.
module ApiPayloads
  # Builds a Hetzner API server payload.
  #
  # @param overrides [Hash] keys to override in the generated payload
  # @return [Hash] a server hash shaped like the Hetzner Cloud API returns
  def server_payload(overrides = {})
    {
      "id" => 42,
      "name" => "kitchen-default-ubuntu-2404-abc123",
      "status" => "running",
      "created" => "2026-08-22T10:00:00+00:00",
      "public_net" => { "ipv4" => { "ip" => "203.0.113.10" }, "ipv6" => { "ip" => "2001:db8::/64" } },
    }.merge(overrides)
  end

  # Builds a Hetzner API action payload.
  #
  # @param overrides [Hash] keys to override in the generated payload
  # @return [Hash] an action hash shaped like the Hetzner Cloud API returns
  def action_payload(overrides = {})
    {
      "id" => 1001,
      "command" => "create_server",
      "status" => "success",
      "progress" => 100,
      "error" => nil,
    }.merge(overrides)
  end
end
