# zink

Zink keeps your symlinks in sync!

## Install With Nix

```sh
nix profile install github:icetan/zink
```

## Usage

Create a zink manifest file which tells zink where to create a symlink and where
it should point to.

```sh
echo > ~/.zink '\
~/.config/sway:$BACKUP_DIR/myconfigs/sway
'
```

Now when you run `zink` it will try to create symlinks as declared in `~/.zink`.

```sh
zink
```

For more information and usage: `zink -h`

## Develop

### Build/Run

```sh
zig build run
```

### Run Tests

```sh
zig build test -Dtest-filter=fs -Dtest-filter=...
```

### Release Build

```sh
zig build -Doptimize=ReleaseSmall
```

### TODO

- [ ] Handle permission denied by prompting with sudo.
