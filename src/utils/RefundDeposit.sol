// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IRefundDeposit.sol";

contract RefundDeposit is IRefundDeposit {
    using SafeERC20 for IERC20;

    function refundDeposit(
        address token,
        address to,
        uint256 amountX18
    ) external {
        IERC20(token).safeTransfer(to, amountX18);

        emit refundDepositProcessed(block.chainid, token, to, amountX18);
    }
}
