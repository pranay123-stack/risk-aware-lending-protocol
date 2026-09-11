// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Roles
/// @notice Role identifiers shared by every contract that consults the ACLManager. Kept as
///         compile-time constants so a role check is one external `hasRole` call, not two.
library Roles {
    /// @notice Risk-increasing configuration. Held by the TimelockController in every deployment.
    bytes32 internal constant POOL_ADMIN = keccak256("POOL_ADMIN");
    /// @notice Instant, risk-reducing actions: pause, freeze, oracle pause. Held by the guardian.
    bytes32 internal constant EMERGENCY_ADMIN = keccak256("EMERGENCY_ADMIN");
    /// @notice The PoolConfigurator contract; the only caller allowed into the pool's setters.
    bytes32 internal constant CONFIGURATOR = keccak256("CONFIGURATOR");
}
