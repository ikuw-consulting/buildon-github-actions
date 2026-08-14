# Kubernetes Run Platform Meta Environment

> See [Guide Usage](../guides/README.md) for how to use the three files.

Minimal build with no overrides.

Builds a deployable run platform (meta environment): a bone-stock
deploy-manifests set for bootstrap, plus the bespoke platform aggregate
(managed run-* children consumed like any other `spec.contents` entry and
the self-referencing deploy-manifests set), the deploy image with its
baked env-var contract including `RUN_CHILDREN_APPLY_MODE=seed-only`, and
the run artifacts.
