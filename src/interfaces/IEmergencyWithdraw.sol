// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

interface IEmergencyWithdraw {
    event emergencyWithdrawTriggered(
        uint256 chainId,
        address token,
        address to,
        uint256 amountX18
    );

    function emergencyWithdraw(address[] calldata tokens, address to) external;
}
