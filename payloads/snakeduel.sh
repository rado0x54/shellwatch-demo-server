#!/bin/sh
# SPDX-License-Identifier: MIT
# `snakeduel` ships in nbsdgames (built from source — not packaged for
# Alpine). Real-time two-snake duel; useful as a quick visual smoke test
# of the SSH path.
exec timeout 1800 snakeduel
