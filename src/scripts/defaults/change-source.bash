#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# change-source.bash - Defaults for change source git notes
#
# The single source of truth for whether merge candidate metadata is recorded
# as a git note. Consumed by the loader (which resolves the KaptainPM.yaml
# value over this default), the writer, and the release change data reader.
#
# shellcheck disable=SC2034  # Variables used by sourcing scripts

CHANGE_SOURCE_NOTE_ENABLED="${CHANGE_SOURCE_NOTE_ENABLED:-true}"
