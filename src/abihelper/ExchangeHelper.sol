// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../interfaces/IOffChainStruct.sol";

interface ExchangeHelper is IOffChainStruct {
    function helper(
        MatchOrderInfo calldata a,
        MatchOrderAMMInfo calldata b,
        MatchOrdersInfo calldata c,
        DepositConfirmInfo calldata d,
        PrepareWithdrawInfo calldata e,
        ExecuteWithdrawInfo calldata f,
        CancelWithdrawInfo calldata f1,
        AmmMatchInfo calldata g,
        FundingFeeInfo calldata h,
        PositionInfo calldata i,
        BalanceInfo calldata j,
        LiquidationInfo calldata k,
        Action l // Can not generate enum to abi
    ) external;

    function lpHelper(
        AddNewPoolInfo calldata a,
        RedeemPoolShareList calldata b,
        RedeemPoolShareInfo calldata c,
        PoolSharePriceInfo calldata d,
        ReBalanceInfoList calldata e,
        TradeProfitSettleList calldata f,
        TradeProfitSettleInfo calldata g,
        WithdrawFeeSettleInfo calldata h,
        ProcessReleasedAssetInfo calldata i,
        ProcessUnLockAssetInfo calldata j
    ) external;
}
