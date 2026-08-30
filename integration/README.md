# Integration suites

The unit suite stubs HTTP at the wire, so it can prove the driver *sends* the
right request but never that Hetzner accepts it. These suites close that gap:
each one creates a real server and asserts, on the instance, that the driver
configured it the way the suite asked for.

They are not part of `rake default`. They create real servers and cost real
money.

## What each suite covers

| Suite | What it proves |
| ----- | -------------- |
| `default` | The whole default path: image derived from the platform name, a generated throwaway keypair uploaded and accepted by sshd, a public IPv4, and a server named after the instance. |
| `image-alias` | `almalinux-9` really does boot Hetzner's `alma-9`. A wrong alias is invisible to a unit test, which only ever compares the mapping to itself. |
| `passthrough-image` | A platform name `ImageMap` passes straight through is a real slug too. |
| `arm64` | A `cax` server type boots the same image slug on Arm64. |
| `user-data` | `user_data` reaches cloud-init intact and runs. |
| `location` | A location other than the default reaches the API, rather than merely being accepted. |
| `server-name` | An explicit `server_name` replaces the generated one, suffix and all. |

Every suite also runs against a driver configured with a label value Hetzner
would reject unsanitized, so a broken `sanitize_label` fails at create rather
than going unnoticed.

## Running them

You need a Hetzner Cloud project and a Read & Write API token. Nothing else has
to exist in the project beforehand — the suites create and destroy everything
they use.

```shell
bundle install
export HCLOUD_TOKEN="your-token-here"
cd integration
bundle exec kitchen list
bundle exec kitchen test default-ubuntu-2404
```

Or from the repository root:

```shell
bundle exec rake integration:list
bundle exec rake integration:test      # everything
bundle exec rake integration:destroy   # clean up after a failed run
```

`kitchen test` destroys on success. It leaves the instance up on failure so you
can log in and look, so **run `kitchen destroy` when you are done** — or
`rake integration:destroy`, which does it for every suite.

### Settings

| Variable | Default | Purpose |
| -------- | ------- | ------- |
| `HCLOUD_TOKEN` | *none* | Required. A Read & Write API token. |
| `KITCHEN_HETZNER_LOCATION` | `fsn1` | Location to create servers in. The `location` suite pins `nbg1` regardless. |
| `KITCHEN_HETZNER_SERVER_TYPE` | `cx22` | Server type. The `arm64` suite pins `cax11` regardless. |
| `KITCHEN_RUN_ID` | `local` | Labelled onto every server, so one that leaks can be traced back to the run that made it. |

### Cost

Seven `cx22`-class servers for a few minutes each. Hetzner bills by the hour
with a per-server minimum, so a full run is a few cents. A run that leaks is
not, which is why every server carries `run-id`:

```shell
hcloud server list -l run-id=local
```

## In CI

`.github/workflows/integration.yml` runs these weekly against `main`, and on
demand through **Actions → Integration Tests → Run workflow**. They are never
triggered by a pull request: secrets are not available to forks, and every run
costs money.

It needs one repository secret:

| Secret | Value |
| ------ | ----- |
| `HCLOUD_TOKEN` | A Read & Write API token for the project CI should use. |

Give CI its own project rather than sharing one with anything else. The suites
only ever delete what they created, but a dedicated project makes a leak
obvious, and `hcloud server list` in it should be empty between runs.

The workflow checks the secret is present before running anything, so a
repository without it fails with one clear message instead of seven HTTP 401s.
`Destroy everything` runs with `if: always()` — a suite that leaks servers on
failure turns a red build into a recurring bill.

## Adding a suite

Add it to `kitchen.yml` and give it arguments for `scripts/assert.sh`. Every
check is one `name=value` argument, so a suite reads as the list of claims it is
making, and a failure names the claim that broke:

```yaml
  - name: my-suite
    includes: [ubuntu-24.04]
    driver:
      some_option: value
    provisioner:
      arguments:
        - metadata
        - os=ubuntu
```

Assertions live in the **provisioner**, not a verifier: the script is
transferred over the driver's own transport and executed on the instance, so
reaching the machine at all is part of every assertion, a non-zero exit fails
the suite, and there is no verifier licence to satisfy.

Keep each suite pointed at one driver option. When it fails, its name should say
what broke.
