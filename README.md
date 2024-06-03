# zink

## Install With Nix

```sh
nix profile install github:icetan/zink
```

## Usage

```sh
echo > ~/.zink '\
$HOME
' >
```

## Build/Run

```sh
zig build run
```

## Run Tests

```sh
zig build test -Dtest-filter=fs -Dtest-filter=...
```

## Release Build

```sh
zig build -Doptimize=ReleaseSmall
```
