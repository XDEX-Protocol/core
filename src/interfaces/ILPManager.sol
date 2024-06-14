// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./IOffChainStruct.sol";
import "./IEmergencyStop.sol";
import "./IReBalance.sol";

interface ILPManager is IOffChainStruct, IEmergencyStop, IReBalance {
    event NewPoolAdded(
        uint64 poolIndex,
        address poolAddress,
        address availableToken,
        uint256 valuePreShare
    );

    event PoolShareValueUpdated(uint64 poolIndex, uint256 newValue);

    event PoolShareAdd(
        uint64 poolIndex,
        address from,
        uint256 shareAmountX18,
        uint256 assetAmountX18
    );

    event redeemRequestReceived(uint64 poolIndex, address from, uint256 share);

    event redeemRequestProcessed(
        bool accept, // request accept, true: redeem processed, false: redeem not processed, withdraw may stopped
        uint64 requestId,
        bool rejected,
        uint256 shareX18,
        uint256 sharePriceX18
    );

    function batchProcess(bytes[] calldata waitProcessData) external;

    function batchProcessAction2(bytes[] calldata waitProcessData) external;

    function modifyOtherModuleAddress(
        uint64 moduleIndex,
        address _newAddress,
        bytes[] calldata signList
    ) external;

    function buyLPShare(
        uint64 poolIndex,
        address from,
        address asset,
        uint256 amountX18
    ) external;

    function redeemRequest(
        uint64 poolIndex,
        address from,
        uint256 share
    ) external;

    function setVaultAddress(address vault) external;

    function getVaultAddress() external view returns (address);

    function availablePoolIndex(uint64 poolIndex) external view returns (bool);

    function getPoolAddress(uint64 poolIndex) external view returns (address);

    function sharePrice(uint64 poolIndex) external view returns (uint256);

    function reciprocalSharePrice(
        uint64 poolIndex
    ) external view returns (uint256);

    function getPoolShareDecimal(
        uint64 poolIndex
    ) external view returns (uint8);

    function getPoolConfigInfo(
        uint64 poolIndex
    )
        external
        view
        returns (
            address poolAddress,
            uint256 maxHoldAsset,
            uint256 minDepositAssetAmount,
            uint256 maxDepositAsset
        );

    function getAssetToken(uint64 poolIndex) external view returns (address);
}
