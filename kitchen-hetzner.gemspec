lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "kitchen/driver/hetzner_version"

Gem::Specification.new do |spec|
  spec.name          = "kitchen-hetzner"
  spec.version       = Kitchen::Driver::HETZNER_VERSION
  spec.authors       = ["Test Kitchen Team"]
  spec.email         = ["help@sous-chefs.org"]
  spec.description   = "A Test Kitchen Driver for Hetzner Cloud"
  spec.summary       = spec.description
  spec.homepage      = "https://github.com/test-kitchen/kitchen-hetzner"
  spec.license       = "Apache-2.0"

  spec.files         = `git ls-files`.split("\n").grep(/LICENSE|^lib/)
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  # Intentionally dependency-free apart from Test Kitchen itself. This driver
  # ships inside Cinc Workstation and Chef Workstation, where each additional
  # dependency (especially a native extension) is a packaging liability. The
  # Hetzner Cloud API surface used here is small enough for Net::HTTP.
  spec.add_dependency "test-kitchen", ">= 3.0", "< 5"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/test-kitchen/kitchen-hetzner/issues",
    "changelog_uri" => "https://github.com/test-kitchen/kitchen-hetzner/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/test-kitchen/kitchen-hetzner/blob/main/README.md",
    "source_code_uri" => "https://github.com/test-kitchen/kitchen-hetzner",
    "rubygems_mfa_required" => "true",
  }
end
