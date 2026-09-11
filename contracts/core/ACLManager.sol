// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IACLManager} from "../interfaces/IACLManager.sol";
import {Errors} from "../libraries/Errors.sol";
import {Roles} from "../libraries/Roles.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title ACLManager
/// @notice Single role registry consulted by the pool, configurator and oracle manager.
/// @dev One registry means one place to audit "who can do what", and revoking a compromised key
///      is a single transaction, not one per contract. In production `DEFAULT_ADMIN_ROLE` and
///      `POOL_ADMIN` are held only by the TimelockController (see script/Deploy.s.sol).
contract ACLManager is AccessControl, IACLManager {
    bytes32 public constant POOL_ADMIN_ROLE = Roles.POOL_ADMIN;
    bytes32 public constant EMERGENCY_ADMIN_ROLE = Roles.EMERGENCY_ADMIN;
    bytes32 public constant CONFIGURATOR_ROLE = Roles.CONFIGURATOR;

    constructor(address admin) {
        if (admin == address(0)) revert Errors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function isPoolAdmin(address account) external view returns (bool) {
        return hasRole(Roles.POOL_ADMIN, account);
    }

    function isEmergencyAdmin(address account) external view returns (bool) {
        return hasRole(Roles.EMERGENCY_ADMIN, account);
    }

    function isConfigurator(address account) external view returns (bool) {
        return hasRole(Roles.CONFIGURATOR, account);
    }
}
