// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./IBaseStruct.sol";

interface IOnChainStruct is IBaseStruct {
    struct OnChainLockConfig {
        uint64 index;
        address asset;
        bool canUpdateConfig;
        LockType lockType;
        uint256 lockAssetAmount;
        bytes configDetail;
    }

    struct OnChainPoolConfig {
        uint64 poolIndex;
        address availableToken;
        uint256 poolMaxHoldAsset;
        uint256 userMinDepositAsset;
        uint256 userMaxDepositAsset;
        uint8 shareDecimal;
        uint8 sharePriceDecimal;
    }
}
