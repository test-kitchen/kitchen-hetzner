require "rspec"
require "webmock/rspec"

WebMock.disable_net_connect!(allow_localhost: true)

require "kitchen"
require "kitchen/driver/hetzner"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

# Builds a Hetzner API server payload with sensible defaults.
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
