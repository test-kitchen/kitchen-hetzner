require "rspec"
require "webmock/rspec"

# Nothing in this suite is allowed near the real API. An unstubbed request
# fails loudly here rather than reaching Hetzner with whatever token happens to
# be in the environment.
WebMock.disable_net_connect!(allow_localhost: true)

require "kitchen"
require "kitchen/driver/hetzner"
# The driver reaches the instance through whatever transport is configured; the
# specs verify their doubles against the SSH one, which is what it will be.
require "kitchen/transport/ssh"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    # Fail if an example stubs a method the real object does not have. Without
    # this, a rename in lib/ leaves the specs stubbing a method that no longer
    # exists, passing green while the driver is broken.
    mocks.verify_partial_doubles = true
  end

  # Surface deprecations as failures rather than warnings that scroll past.
  config.raise_errors_for_deprecations!

  config.include ApiPayloads
  config.include HttpResponses

  config.run_all_when_everything_filtered = true
  config.filter_run(:focus)

  # Run specs in random order to surface order dependencies. To debug one, fix
  # the order by passing the seed printed after each run:
  #     --seed 1234
  config.order = :random
  Kernel.srand config.seed
end
