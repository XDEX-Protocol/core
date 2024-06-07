// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./IOffChainStruct.sol";
import "./IOnChainStruct.sol";
import "./IEmergencyStop.sol";
import "./IRefundDeposit.sol";
import "./IReBalance.sol";

interface ITreasuryManager is
    IOffChainStruct,
    IOnChainStruct,
    IEmergencyStop,
    IRefundDeposit,
    IReBalance
{
    event NewLockConfigAdded(
        uint64 index,
        address lockAsset,
        uint256 lockAssetAmount
    );

    event CanClaimUnlockAssetAdded(
        TreasuryAssetType assetType,
        address token,
        address receipt,
        uint256 amount,
        bool airDroped
    );

    event UnlockAssetClaimed(
        TreasuryAssetType assetType,
        address token,
        address receipt,
        uint256 amount
    );

    function deposit(
        TreasuryAssetType assetType,
        address asset,
        uint256 amount
    ) external;

    function batchProcess(bytes[] calldata waitProcessData) external;

    function batchProcessAction2(bytes[] calldata waitProcessData) external;

    function modifyOtherModuleAddress(
        uint64 moduleIndex,
        address _newAddress,
        bytes[] calldata signList
    ) external;

    function setVaultAddress(address vault) external;

    function refreshCanReleaseAssetAmount(
        TreasuryAssetType assetType,
        uint64[] calldata index
    ) external;

    function claimReleasedAsset(
        TreasuryAssetType assetType,
        uint64 index
    ) external returns (address asset, uint256 amount);

    function claimUnLockAsset(
        TreasuryAssetType assetType,
        address asset
    ) external returns (uint256 amount);

    function getAvailableAmount(
        TreasuryAssetType assetType,
        uint64 index,
        address walletAddr
    ) external returns (uint256 amount, address asset, uint8 decimal);

    function getVaultAddress() external view returns (address);
}
