# Kubernetes Run Environment

> See [Guide Usage](../guides/README.md) for how to use the three files.

Minimal build with no overrides.

Builds a deployable environment: a bone-stock deploy-manifests set for
the consuming parent or bootstrap, plus the bespoke workload aggregate
(`spec.contents` children and the self-referencing deploy-manifests set),
the deploy image with its baked env-var contract, and the run artifacts
(environment contents zip, consumption report, artifacts wrapper image).
