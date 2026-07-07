// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title FmeaRegistry — L2 append-only tool gap ledger (X6).
/// @notice No settlement gate; no confirm-blocking; zero cell hooks. Claim module records gaps on exploit resolve.
contract FmeaRegistry {
    bytes32 public constant unclassifiedVulnerabilityClass = keccak256("dan:fmea:unclassified");

    struct VulnerabilityClass {
        bytes32 metadataHash;
        address proposer;
        bool exists;
    }

    mapping(bytes32 => VulnerabilityClass) public vulnerabilityClasses;
    mapping(bytes32 => bytes32[]) internal _toolKnownGaps;
    mapping(bytes32 => mapping(bytes32 => bool)) public toolHasGap;
    mapping(uint256 => bytes32) public claimVulnerabilityClassId;

    address public admin;
    address public claimModule;
    bool public wiringLocked;

    event VulnerabilityClassRegistered(bytes32 indexed classId, address indexed proposer, bytes32 metadataHash);
    event ToolGapRecorded(bytes32 indexed toolId, bytes32 indexed classId, uint256 indexed auditId);

    error NotAdmin();
    error NotClaimModule();
    error WiringLocked();
    error HostUnset();
    error EmptyClassId();
    error EmptyMetadataHash();
    error ClassAlreadyRegistered();
    error ClassNotRegistered();

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyClaimModule() {
        if (msg.sender != claimModule) revert NotClaimModule();
        _;
    }

    constructor(address _admin) {
        admin = _admin;
        bytes32 unclassified = unclassifiedVulnerabilityClass;
        vulnerabilityClasses[unclassified] = VulnerabilityClass({
            metadataHash: keccak256("dan:fmea:unclassified:v1"),
            proposer: msg.sender,
            exists: true
        });
        emit VulnerabilityClassRegistered(unclassified, msg.sender, keccak256("dan:fmea:unclassified:v1"));
    }

    function wireClaimModule(address _claimModule) external onlyAdmin {
        if (wiringLocked) revert WiringLocked();
        claimModule = _claimModule;
    }

    function lockWiring() external onlyAdmin {
        if (claimModule == address(0)) revert HostUnset();
        wiringLocked = true;
    }

    function registerVulnerabilityClass(bytes32 classId, bytes32 metadataHash) external {
        if (classId == bytes32(0)) revert EmptyClassId();
        if (metadataHash == bytes32(0)) revert EmptyMetadataHash();
        if (vulnerabilityClasses[classId].exists) revert ClassAlreadyRegistered();
        vulnerabilityClasses[classId] = VulnerabilityClass({
            metadataHash: metadataHash,
            proposer: msg.sender,
            exists: true
        });
        emit VulnerabilityClassRegistered(classId, msg.sender, metadataHash);
    }

    /// @dev Called when a claim is filed; classId zero resolves to unclassified on gap record.
    function noteClaimClass(uint256 auditId, bytes32 classId) external onlyClaimModule {
        if (classId != bytes32(0) && !vulnerabilityClasses[classId].exists) revert ClassNotRegistered();
        claimVulnerabilityClassId[auditId] = classId;
    }

    /// @dev Append-only gap on exploit resolution (dispute FAIL reproduce).
    function recordClaimGap(uint256 originalAuditId, bytes32 specToolId) external onlyClaimModule {
        if (specToolId == bytes32(0)) return;
        bytes32 declared = claimVulnerabilityClassId[originalAuditId];
        bytes32 classId = declared == bytes32(0) ? unclassifiedVulnerabilityClass : declared;
        if (toolHasGap[specToolId][classId]) return;
        toolHasGap[specToolId][classId] = true;
        _toolKnownGaps[specToolId].push(classId);
        emit ToolGapRecorded(specToolId, classId, originalAuditId);
    }

    function toolKnownGapCount(bytes32 toolId) external view returns (uint256) {
        return _toolKnownGaps[toolId].length;
    }

    function toolKnownGapAt(bytes32 toolId, uint256 index) external view returns (bytes32) {
        return _toolKnownGaps[toolId][index];
    }
}
