// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Vm} from "forge-std/Vm.sol";

/**
 * GenesisAuditorKey - the genesis auditor's key, and nothing standing in for it (PC-86, 2026-09-15).
 *
 * `GenesisBootstrapRegister` and `GenesisBootstrapAuditor` both read `AUDITOR_PRIVATE_KEY` and, when it was absent,
 * silently fell back to `PRIVATE_KEY` - the deployer's. The deployer is also the genesis PROTOCOL
 * (`GenesisBootstrapProtocol` broadcasts with `PRIVATE_KEY`), so one forgotten variable registered the deployer at
 * position 1 and then stalled genesis on `SelfAuditDisallowed`, with the real auditor's slot already consumed.
 * Absence is not a decision the operator made (the `EnvReads` rule, one variable over).
 *
 * THE RULE: `AUDITOR_PRIVATE_KEY` is required, and when `PRIVATE_KEY` is also in the environment the two must not
 * name the same address. A LIBRARY for the reason `EnvCell` is one: both callers already inherit `InstanceAware`.
 * `resolve` takes values, not names, because Foundry pins an env key on its first read in a test process.
 */
library GenesisAuditorKey {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function fromEnv() internal view returns (uint256) {
        bool hasAuditor = bytes(VM.envOr("AUDITOR_PRIVATE_KEY", string(""))).length > 0;
        bool hasDeployer = bytes(VM.envOr("PRIVATE_KEY", string(""))).length > 0;
        return resolve(
            hasAuditor,
            hasAuditor ? VM.envUint("AUDITOR_PRIVATE_KEY") : 0,
            hasDeployer,
            hasDeployer ? VM.envUint("PRIVATE_KEY") : 0
        );
    }

    function resolve(bool hasAuditorKey, uint256 auditorKey, bool hasDeployerKey, uint256 deployerKey)
        internal
        pure
        returns (uint256)
    {
        require(hasAuditorKey, "AUDITOR_PRIVATE_KEY is required - it no longer falls back to PRIVATE_KEY (PC-86)");
        if (hasDeployerKey) {
            require(
                VM.addr(auditorKey) != VM.addr(deployerKey),
                "AUDITOR_PRIVATE_KEY names the deployer - the genesis protocol cannot audit itself (PC-86)"
            );
        }
        return auditorKey;
    }
}
