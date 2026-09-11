// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

interface IACLManager is IAccessControl {
    function isPoolAdmin(address account) external view returns (bool);
    function isEmergencyAdmin(address account) external view returns (bool);
    function isConfigurator(address account) external view returns (bool);
}
