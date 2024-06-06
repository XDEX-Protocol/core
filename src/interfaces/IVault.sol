// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

interface IVault {
    event withdrawProcessed(address to, address token, uint256 amount);

    function withdraw(address to, address token, uint256 amount) external;
}
