#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# schema-validation.bash - Schema validation provider selected by validate-tooling
#
# Holds the full path to the schema validation plugin to invoke, called as
# "${SCHEMA_VALIDATION_COMMAND}" <schema-file> <target-file>
#
# shellcheck disable=SC2034  # Variables used by sourcing scripts

SCHEMA_VALIDATION_COMMAND="${SCHEMA_VALIDATION_COMMAND:?SCHEMA_VALIDATION_COMMAND is required - run validate-tooling first}"
