source "https://rubygems.org"

gemspec

group :test do
  gem "rake"
  gem "rspec", "~> 3.13"
  gem "webmock", "~> 3.19"
end

group :cookstyle do
  gem "cookstyle"
end

group :development do
  gem "yard", "~> 0.9"
end

# Only needed to run the suites in integration/, which create real servers.
# `bundle install --without integration` skips them.
group :integration do
  # The driver generates an RSA key. Hetzner's images run sshd 8.8 or newer,
  # which will not accept the ssh-rsa signature algorithm; net-ssh 7 negotiates
  # rsa-sha2-256/512 instead, and older resolutions of this tree can otherwise
  # pick up a net-ssh that cannot.
  gem "net-ssh", "~> 7.3"
end
