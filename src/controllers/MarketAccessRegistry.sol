// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Id} from "@morpho-blue/src/interfaces/IMorpho.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IMarketAccessRegistry} from "../interfaces/IMarketAccessRegistry.sol";

/// @title MarketAccessRegistry
/// @notice Stores global and market-position access restrictions for one Lido Lending deployment.
/// @dev Policy semantics live in the market controller. This registry only answers whether an
///      address or `(market id, address)` pair is blocked.
contract MarketAccessRegistry is IMarketAccessRegistry, AccessControl {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    error ZeroAddress();

    event AddressBlocked(address indexed subject, address indexed by);
    event AddressUnblocked(address indexed subject, address indexed by);
    event PositionBlocked(Id indexed id, address indexed subject, address indexed by);
    event PositionUnblocked(Id indexed id, address indexed subject, address indexed by);

    mapping(address => bool) public override addressBlocked;
    mapping(Id => mapping(address => bool)) public override positionBlocked;

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function blockAddress(address user) external onlyRole(OPERATOR_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        addressBlocked[user] = true;
        emit AddressBlocked(user, msg.sender);
    }

    function unblockAddress(address user) external onlyRole(OPERATOR_ROLE) {
        delete addressBlocked[user];
        emit AddressUnblocked(user, msg.sender);
    }

    function blockPosition(Id id, address user) external onlyRole(OPERATOR_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        positionBlocked[id][user] = true;
        emit PositionBlocked(id, user, msg.sender);
    }

    function unblockPosition(Id id, address user) external onlyRole(OPERATOR_ROLE) {
        delete positionBlocked[id][user];
        emit PositionUnblocked(id, user, msg.sender);
    }

    function isBlocked(Id id, address user) external view returns (bool) {
        return addressBlocked[user] || positionBlocked[id][user];
    }
}
