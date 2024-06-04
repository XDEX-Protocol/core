// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

interface IReBalance {
    function reBalanceToUserManager(address token, uint256 amountX18) external;
}
