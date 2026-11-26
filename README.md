# huen-mousenap

`huen-mousenap` hides the macOS mouse cursor after an idle timeout and shows it again on mouse movement.

Park the pointer in the middle of a terminal and it sits right over the one character you are trying to read. Every real mouse knows better and curls up out of sight the moment nobody is looking. `huen-mousenap` gives your cursor the same manners, putting it down for a nap until you nudge it again.

## Requirements

- macOS 14 or newer
- Zig 0.17.1 and `mise`

## Install

Build and install the binary into `~/.local/bin`:

```sh
mise run install
```

Or build into `zig-out/bin/huen-mousenap`:

```sh
mise run build
```

## Usage

Run in the foreground:

```sh
huen-mousenap
huen-mousenap run --timeout 2.5 --poll-interval 25
huen-mousenap run --print-state
```

Print the resolved configuration as TOML:

```sh
huen-mousenap config
huen-mousenap config --config /path/to/config.toml --timeout 5
```

Show help or version:

```sh
huen-mousenap help
huen-mousenap version
```

Flags:

- `-c`, `--config <path>` loads a specific TOML file. A missing explicit file exits with an error.
- `-t`, `--timeout <sec>` overrides `timeout_seconds`.
- `--poll-interval <ms>` overrides `poll_interval_ms`.
- `--print-state` writes `hidden` or `visible` to stdout on each state change during `run`.
- `-h`, `--help` prints usage and exits 0.
- `-V`, `--version` prints `huen-mousenap 0.1.0` and exits 0.

## Configuration

When you do not pass `--config`, `huen-mousenap` checks `$XDG_CONFIG_HOME/huen-mousenap/config.toml` if `XDG_CONFIG_HOME` is non-empty and absolute. Otherwise it checks `$HOME/.config/huen-mousenap/config.toml`. If the default file does not exist, `huen-mousenap` uses the defaults.

See `config/example.toml`:

```toml
timeout_seconds = 3.0
poll_interval_ms = 25
```

Bounds:

- `timeout_seconds` must be finite, greater than `0`, and at most `86400`.
- `poll_interval_ms` must be an integer from `5` to `1000`.

CLI flags take precedence over values in the config file.

## Signals

- `SIGINT` and `SIGTERM` restore the cursor if hidden and exit 0.
- `SIGHUP` reloads the config file and reapplies any CLI overrides. If the reloaded file is invalid, `huen-mousenap` writes an error to stderr and keeps the last valid config.

## Development

Install the Git hooks:

```sh
mise trust
mise install
mise exec -- hk install --mise
```

Run the runner tests, CLI smoke tests, and lint checks:

```sh
mise exec -- zig build install test smoke
mise run check
```
