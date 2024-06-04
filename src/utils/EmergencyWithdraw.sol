// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IEmergencyWithdraw.sol";

contract EmergencyWithdraw is IEmergencyWithdraw {
    using SafeERC20 for IERC20;

    function emergencyWithdraw(address[] calldata tokens, address to) external {
        for (uint256 index = 0; index < tokens.length; index++) {
            uint256 balance = IERC20(tokens[index]).balanceOf(address(this));
            IERC20(tokens[index]).safeTransfer(to, balance);

            emit emergencyWithdrawTriggered(
                block.chainid,
                tokens[index],
                to,
                balance
            );
        }
    }
}
