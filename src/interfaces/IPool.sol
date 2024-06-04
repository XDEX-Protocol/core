// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IPool is IERC20 {
    event configUpdated(
        uint256 maxHoldAsset,
        uint256 minDepositAssetamountX18Once,
        uint256 maxDepositAsset
    );

    function buyShare(address user, uint256 share) external;

    function burnRedeemShare(uint256 burnShare) external;

    function rejectRedeemShare(address rejectAddress, uint256 share) external;
}
