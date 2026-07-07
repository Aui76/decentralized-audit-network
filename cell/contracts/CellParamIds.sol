// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @dev G6 param-lock bitmap ids (must match CellLogicLib).
library CellParamIds {
    uint8 internal constant CLAIM_RESOLUTION = 0;
    uint8 internal constant CLAIM_FILING_STAKE = 1;
    uint8 internal constant CANONICAL_THRESHOLD = 2;
    uint8 internal constant MAX_BOOST = 3;
    uint8 internal constant DISCOVERY_CAP = 4;
    uint8 internal constant DISCOVERY_FLOOR = 5;
    uint8 internal constant DISPUTE_MODULES = 6;
    uint8 internal constant TREASURY_ESCROW = 7;
    uint8 internal constant MIN_AUDIT = 8;
    uint8 internal constant DECISION = 9;
    uint8 internal constant PROTOCOL_DECISION = 10;
    uint8 internal constant IN_AUDIT = 11;
    uint8 internal constant CLAIM_STAKE_BPS = 12;
    uint8 internal constant ID_MAX = 12;
}
