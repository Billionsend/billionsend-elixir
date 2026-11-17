#!/bin/sh
# Runs the checks in the pinned Elixir image (podman or docker), the same as CI.
set -eu
image=docker.io/library/elixir:1.18.4-slim
runtime=$(command -v podman || command -v docker)
exec "$runtime" run --rm -v "$PWD:/w:Z" -w /w -e MIX_HOME=/w/_build/mix "$image" sh -c '
  elixir scripts/generate.exs --check &&
  mix format --check-formatted &&
  mix compile --warnings-as-errors &&
  mix test --warnings-as-errors'
