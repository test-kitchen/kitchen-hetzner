# kitchen-hetzner

[![Gem Version](https://badge.fury.io/rb/kitchen-hetzner.svg)](https://badge.fury.io/rb/kitchen-hetzner)
[![Test](https://github.com/test-kitchen/kitchen-hetzner/actions/workflows/lint.yml/badge.svg)](https://github.com/test-kitchen/kitchen-hetzner/actions/workflows/lint.yml)

A [Test Kitchen](https://github.com/test-kitchen/test-kitchen) driver for
[Hetzner Cloud](https://www.hetzner.com/cloud/). It creates a cloud server for
each test instance, runs your converge and verify against it, and destroys it
again.

Hetzner Cloud is a good fit for cookbook testing: servers boot in seconds, are
billed by the hour, and Arm64 instances cost about the same as x86, which makes
a multi-architecture test matrix affordable.

## Requirements

- Ruby 3.1 or later
- A [Hetzner Cloud](https://console.hetzner.cloud/) project and API token
- Test Kitchen 3.0 or later

This driver has **no runtime dependencies** beyond Test Kitchen itself. It talks
to the Hetzner Cloud API over `Net::HTTP` from the standard library, so there is
nothing to compile and nothing to conflict with the gems already inside Cinc
Workstation or Chef Workstation.

## Installation

If you use **Cinc Workstation** or **Chef Workstation**, install into the same
Ruby that runs `kitchen`:

```shell
cinc gem install kitchen-hetzner
# or, for Chef Workstation
chef gem install kitchen-hetzner
```

With Bundler, add it to your `Gemfile`:

```ruby
gem "kitchen-hetzner"
gem "kitchen-cinc"           # cinc_infra provisioner
gem "kitchen-cinc-auditor"   # cinc_auditor verifier
```

## Getting started

### 1. Create an API token

In the [Hetzner Cloud Console](https://console.hetzner.cloud/), open your
project, then **Security → API tokens → Generate API token**. Give it
**Read & Write** permission — the driver needs to create and delete servers.

Export it as `HCLOUD_TOKEN`, the same variable Hetzner's own `hcloud` CLI uses:

```shell
export HCLOUD_TOKEN="your-token-here"
```

### 2. Write a kitchen.yml

```yaml
---
driver:
  name: hetzner

provisioner:
  name: cinc_infra

verifier:
  name: cinc_auditor

platforms:
  - name: ubuntu-24.04
  - name: debian-12
  - name: almalinux-9

suites:
  - name: default
    run_list:
      - recipe[my_cookbook::default]
```

That is the whole configuration. With no `ssh_keys` set, the driver generates a
throwaway keypair for each run, uploads it, and deletes it on `kitchen destroy`.

### 3. Run it

```shell
kitchen test
```

## Configuration

| Option | Default | Description |
| ------ | ------- | ----------- |
| `hetzner_token` | `$HCLOUD_TOKEN` | API token with read/write access. Falls back to `$HETZNER_TOKEN`. |
| `server_type` | `cx22` | Hetzner server type. Use a `cax*` type for Arm64. |
| `location` | `fsn1` | Location slug: `fsn1`, `nbg1`, `hel1`, `ash`, `hil`, `sin`. |
| `image` | derived from the platform name | Image slug or a snapshot ID. |
| `ssh_keys` | `nil` | Existing Hetzner SSH key names or IDs. When unset, a throwaway key is generated. |
| `user_data` | `nil` | cloud-init user data. |
| `labels` | `{}` | Extra labels to apply to the server. |
| `server_name` | generated | Override the generated server name. |
| `username` | `root` | SSH user. |
| `port` | `22` | SSH port. |
| `server_ready_timeout` | `600` | Seconds to wait for the create action to finish. |
| `api_url` | `https://api.hetzner.cloud/v1` | API root, mainly useful for testing. |

Run `kitchen diagnose` to see the fully resolved configuration for an instance.

### Platform names and images

Most Test Kitchen platform names match Hetzner's image slugs exactly and are
passed straight through. Only genuine mismatches are translated:

| Platform in `kitchen.yml` | Hetzner image |
| ------------------------- | ------------- |
| `ubuntu-24.04` | `ubuntu-24.04` |
| `debian-12` | `debian-12` |
| `rocky-9` | `rocky-9` |
| `centos-stream-9` | `centos-stream-9` |
| `almalinux-9` | `alma-9` |

Set `image` explicitly to use anything else, including your own snapshots:

```yaml
platforms:
  - name: my-golden-image
    driver:
      image: 123456   # snapshot ID
```

Run `hcloud image list` to see what your project can boot.

## Examples

### Testing on Arm64

Hetzner's `cax` server types are Ampere Arm64. The image slug is the same; the
architecture follows the server type.

```yaml
platforms:
  - name: ubuntu-24.04
    driver:
      server_type: cax11
```

Mixing architectures in one matrix works well:

```yaml
platforms:
  - name: ubuntu-24.04
    driver:
      server_type: cx22    # x86_64
  - name: ubuntu-24.04-arm
    driver:
      server_type: cax11   # arm64
      image: ubuntu-24.04
```

### Reusing an existing SSH key

In CI you may prefer a key you manage yourself. When `ssh_keys` is set, the
driver creates and deletes nothing:

```yaml
driver:
  name: hetzner
  ssh_keys:
    - my-ci-key      # name or numeric ID

transport:
  ssh_key: ~/.ssh/id_ed25519
```

### cloud-init user data

```yaml
driver:
  name: hetzner
  user_data: |
    #cloud-config
    package_update: true
    packages:
      - curl
```

### Labelling servers

Every server is labelled `created_by=test-kitchen` and
`kitchen_instance=<instance name>`. You can add your own:

```yaml
driver:
  name: hetzner
  labels:
    team: infra
    ci_job: nightly
```

## Cleaning up orphaned servers

If CI is cancelled between `create` and `destroy`, the server keeps running and
no local state file remains to clean it up. Because every server this driver
creates is labelled, they are easy to find:

```shell
kitchen doctor default-ubuntu-2404
```

This reports servers labelled `created_by=test-kitchen` that no local Test
Kitchen state file knows about, and prints the command to remove them. It never
deletes anything itself, since a Hetzner project may be shared with other work.

You can also find them directly:

```shell
hcloud server list -l created_by=test-kitchen
```

## Using Chef instead of Cinc

The examples above use Cinc, but this driver is provisioner-agnostic — it only
creates and destroys servers. To use Chef Infra, swap the provisioner and
verifier:

```yaml
provisioner:
  name: chef_infra

verifier:
  name: inspec
```

Everything under `driver:` stays the same.

## Limitations

- **No Windows.** Hetzner Cloud does not offer Windows images. Pointing a
  `windows-*` platform at this driver fails immediately with an explanation
  rather than a confusing API error. Use `kitchen-ec2` or `kitchen-azurerm` for
  Windows.
- **Public IPv4 required.** The driver connects over the server's public IPv4
  address and fails if one was not assigned.

## Development

```shell
bundle install
bundle exec rake test    # RSpec unit tests
bundle exec rake style   # cookstyle --chefstyle
bundle exec rake docs    # YARD documentation
bundle exec rake         # test + style
```

The unit tests are offline: HTTP is stubbed with WebMock and no API token is
needed.

Stubbing at the wire proves the driver sends the right request, not that Hetzner
accepts it. The suites in [`integration/`](integration/README.md) close that gap
— each creates a real server and asserts, on the instance, that it was
configured as asked:

```shell
export HCLOUD_TOKEN="your-token-here"
bundle exec rake integration:list
bundle exec rake integration:test
bundle exec rake integration:destroy   # after a failed run
```

They are not part of `rake default` — they cost money — and never run on a pull
request. Maintainers run them on demand, and weekly against `main`.

## Contributing

Bug reports and pull requests are welcome at
<https://github.com/test-kitchen/kitchen-hetzner>.

## License

Copyright the Test Kitchen authors.

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).
