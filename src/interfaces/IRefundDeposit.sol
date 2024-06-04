// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

interface IRefundDeposit {
    event refundDepositProcessed(
        uint256 chainId,
        address token,
        address to,
        uint256 amountX18
    );

    function refundDeposit(
        address token,
        address to,
        uint256 amountX18
    ) external;
}
