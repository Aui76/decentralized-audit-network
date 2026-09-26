// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import "./EnvReads.s.sol";

/*
 * Shared instance-record path resolution for rung/disposable deploys (2026-07-29).
 *
 * DeployCell._deploymentJsonPath routes a labeled deploy (DEPLOY_INSTANCE_LABEL=<label>)
 * to deployments/<chainid>-<label>.json so it CANNOT clobber the canonical live record
 * (the 2026-07-19 records-integrity incident, d331dfd). That fix covered the WRITER only:
 * every downstream script (VerifyWiring, GenesisBootstrap*, LockMinter, LockWiring) still
 * fell back to deployments/<chainid>.json -- which on 84532 is the FROZEN LIVE CELL. A
 * labeled rung deploy followed by an unlabeled genesis would have broadcast AGAINST THE
 * LIVE ANCHOR, and VerifyWiring would have green-lit the wrong instance.
 *
 * Rule: one label, one instance, everywhere. Any script that resolves a deployment or
 * genesis record inherits this and uses these helpers, so setting DEPLOY_INSTANCE_LABEL
 * once steers the ENTIRE sequence to the same instance files:
 *   deployments/<chainid>[-<label>].json          (deployment record)
 *   deployments/genesis-<chainid>[-<label>].json  (genesis record -- also label-keyed, so a
 *                                                  rung genesis never clobbers another
 *                                                  instance's committed genesis evidence)
 * Explicit env overrides (AUDIT_CELL, CELL_TOKEN, ISSUANCE_MODULE, AUDIT_ID,
 * GENESIS_ARTIFACT) keep priority over the resolved paths in every caller.
 *
 * DeployCell keeps its own private copy of this logic (plus dryrun handling) -- it is the
 * freeze-reviewed writer and is deliberately not re-touched here; the two MUST stay in
 * agreement on the "<chainid>-<label>.json" shape.
 */
abstract contract InstanceAware is EnvReads {
    // THE ENV HELPERS MOVED AGAIN, to `EnvReads.s.sol` (PC-67 closed, 2026-09-11). They landed
    // here first, which was already better than the private copy they came from - but this base
    // also builds deployment-record paths, and its header says those must stay in agreement with
    // `DeployCell`'s. So inheriting it to get an env helper drags a path-builder along, and the
    // sixteen phase/demo scripts that needed the helper did not want one. A base with ONE job can
    // be inherited by anything; this one has two. `InstanceAware is EnvReads`, so every caller of
    // this base still has them.

    function _instanceLabel() internal view returns (string memory) {
        return vm.envOr("DEPLOY_INSTANCE_LABEL", string(""));
    }

    /// @dev deployments/<chainid>.json, or deployments/<chainid>-<label>.json when
    ///      DEPLOY_INSTANCE_LABEL is set. Matches DeployCell._deploymentJsonPath (broadcast leg).
    function _deploymentRecordPath() internal view returns (string memory) {
        string memory base = string.concat("deployments/", vm.toString(block.chainid));
        string memory label = _instanceLabel();
        if (bytes(label).length > 0) {
            base = string.concat(base, "-", label);
        }
        return string.concat(base, ".json");
    }

    /// @dev deployments/genesis-<chainid>.json, or deployments/genesis-<chainid>-<label>.json
    ///      when DEPLOY_INSTANCE_LABEL is set.
    function _genesisRecordPath() internal view returns (string memory) {
        string memory base = string.concat("deployments/genesis-", vm.toString(block.chainid));
        string memory label = _instanceLabel();
        if (bytes(label).length > 0) {
            base = string.concat(base, "-", label);
        }
        return string.concat(base, ".json");
    }
}
