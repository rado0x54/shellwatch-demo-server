#!/bin/sh
# SPDX-License-Identifier: MIT
# `snake` ships in the bsd-games package alongside a few other classic
# games we don't expose (atc, robots, adventure, etc.).
exec timeout 600 snake
