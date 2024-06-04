// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./IBaseStruct.sol";

interface IOffChainStruct is IBaseStruct {
    // action will change user balance
    enum Action {
        depositConfirm,
        prepareWithdraw,
        executeWithdraw,
        cancelWithdraw,
        matchOrders,
        matchOrderAMM,
        liquidate,
        fundingSettle,
        tradeProfitSettle,
        withdrawFeeSettle,
        activitySettle,
        frozenUserAsset,
        unfrozenUserAsset,
        internalTransfer
    }

    // actions that will not change user balance directly
    enum Action2 {
        addNewPool,
        updatePoolConfig,
        updatePoolSharePrice,
        redeemPoolShare,
        reBalance,
        addTreasuryLockConfig,
        processTreasuryReleasedAsset,
        processTreasuryUnLockAsset,
        transferTreasuryReleasedAssetToOtherModule,
        transferTreasuryUnLockAssetToOtherModule
    }

    enum OrderSide {
        long,
        short
    }

    // deposit confirm
    struct DepositConfirmInfo {
        uint64 orderId;
        uint64 uid;
        uint64 aid;
        address from;
        address token;
        uint256 amountX18;
    }

    // prepare withdraw
    struct PrepareWithdrawInfo {
        uint64 orderId;
        uint64 uid;
        uint64 aid;
        address token;
        uint256 amountX18;
        uint256 fee;
        bytes userSign;
    }

    struct ExecuteWithdrawInfo {
        uint64 orderId;
    }

    struct CancelWithdrawInfo {
        uint64 orderId;
    }

    /// @dev only for struct {MatchOrdersInfo} and struct {MatchOrderAMMInfo}
    struct MatchOrderInfo {
        uint64 uid;
        uint64 aid;
        OrderSide side;
        uint256 price;
        int256 qty; // quantity
        uint256 amountX18;
        int256 fee; // trade fee
        int256 pnl; // for close order
        /// @dev only for user sign check and emit event
        uint8 orderType;
        uint8 timeInForce;
        uint8 reduceOnly;
        bytes userSign;
    }

    /// @dev only for struct {MatchOrderAMMInfo}
    struct AmmMatchInfo {
        OrderSide side; // 0: Long   1: Short
        uint256 price; // can't less than zero
        int256 qty; // position
        uint256 amountX18;
        int256 fee; // trade fee
        int256 pnl; // for close order
    }

    /// @dev when two user order match
    struct MatchOrdersInfo {
        uint64 symbolIndex;
        address token;
        int256 feeProfit;
        uint64 ticketId;
        uint64 poolIndex;
        MatchOrderInfo maker;
        MatchOrderInfo taker;
    }

    /// @dev when user order match amm
    struct MatchOrderAMMInfo {
        uint64 symbolIndex;
        address token;
        bool userIsMaker;
        int256 feeProfit;
        uint64 ticketId;
        uint64 poolIndex;
        MatchOrderInfo user;
        AmmMatchInfo amm;
    }

    /// @dev only for struct {LiquidationInfo}
    struct PositionInfo {
        uint64 aid;
        uint64 symbolIndex;
        int256 qty; // >0 for long, <0 for short
        uint64 receivePoolIndex;
    }

    /// @dev only for struct {LiquidationInfo}
    struct BalanceInfo {
        uint64 aid;
        address token;
        int256 amountX18;
        uint64 receivePoolIndex;
    }

    /// @dev liquidation user's balance turn to zero, and amm will receive all user position
    struct LiquidationInfo {
        uint64 aid;
        uint64 LiquidationId;
        PositionInfo[] positionList;
        BalanceInfo[] balanceList;
    }

    /// @dev funding fee
    struct FundingFeeInfo {
        uint64 time;
        uint64 symbolIndex;
        address token;
        uint64 aid;
        uint64 poolIndex;
        int256 fee;
    }

    enum ProfitSettleType {
        AllocPnlToLP, // 分配交易盈利
        TradeFeeToPlatform, //
        TradeFeeToLP, // 流动性池 index
        TradeFeeToTreasury // 流动性池 index
    }

    struct TradeProfitSettleInfo {
        address token;
        uint256 amount;
        ProfitSettleType settleType;
        uint64 fromId;
        uint64 toId;
    }

    /// @dev
    struct TradeProfitSettleList {
        TradeProfitSettleInfo[] list;
    }

    /// @dev
    struct WithdrawFeeSettleInfo {
        address token;
        int256 withdrawFeeAmountX18;
        int256 toTreasuryAmountX18;
        uint64 toLPIndex;
        int256 toLPAmountX18;
    }

    /// @dev
    struct ActivitySettleInfo {
        uint64 activityId;
        uint64 settleBatchNum;
        address token;
        uint64 fromAId;
        uint64 toAId;
        int256 changedAmountX18;
        string reason;
    }

    /// @dev
    struct FrozenUserAsset {
        uint64 uid;
        uint64 aid;
        address token;
        uint256 amountX18;
        string reason;
    }

    /// @dev
    struct UnFrozenUserAsset {
        uint64 uid;
        uint64 aid;
        address token;
        uint256 amountX18;
        string reason;
    }

    /// @dev
    struct InternalTransferInfo {
        uint64 transferType;
        uint64 fromUid;
        uint64 fromAid;
        uint64 toUid;
        uint64 toAid;
        address token;
        uint256 amountX18;
        string reason;
    }

    struct PoolConfigInfo {
        uint64 poolIndex;
        address availableToken;
        uint256 maxHoldAssetX18;
        uint256 minDepositAssetAmountX18;
        uint256 maxDepositAssetX18;
        uint8 shareDecimal;
        uint8 sharePriceDecimal;
    }

    /// @dev
    struct AddNewPoolInfo {
        uint64 poolIndex;
        address availableToken;
        uint256 sharePriceX18;
        uint256 reciprocalSharePriceX18;
        uint256 maxHoldAssetX18;
        uint256 minDepositAssetAmountX18;
        uint256 maxDepositAssetX18;
        string _shareName;
        string _shareSymbol;
        uint8 shareDecimal;
        uint8 sharePriceDecimal;
    }

    /// @dev
    struct UpdatePoolConfigInfo {
        uint64 poolIndex;
        uint256 maxHoldAssetX18;
        uint256 minDepositAssetAmountX18;
        uint256 maxDepositAssetX18;
    }

    /// @dev pool share value
    struct PoolSharePriceInfo {
        uint64[] poolIndex;
        uint256[] sharePriceX18;
        uint256[] reciprocalSharePriceX18;
    }

    /// @dev
    struct RedeemPoolShareInfo {
        uint64 requestId;
        uint64 poolIndex;
        uint256 sharePriceX18;
        uint256 reciprocalSharePriceX18;
        bool approved;
        address toAddress;
        uint256 shareX18;
    }

    /// @dev
    struct RedeemPoolShareList {
        RedeemPoolShareInfo[] list;
    }

    /// @dev
    struct ReBalanceInfoList {
        address token;
        uint64[] settlePoolIndexList;
    }

    /// @dev
    struct ReBalanceToUserManagerInfo {
        address token;
        uint256 amountX18;
    }

    struct AddTreasuryLockConfigInfo {
        uint64 index;
        address lockAsset;
        bool canUpdateConfig;
        LockType lockType;
        uint256 lockAssetAmountX18;
        bytes configDetail;
    }

    struct ProcessReleasedAssetInfo {
        bool needAirDrop;
        uint64 index;
        address[] recipients;
        uint256[] amountX18List;
    }

    struct ProcessUnLockAssetInfo {
        bool needAirDrop;
        address token;
        address[] recipients;
        uint256[] amountX18List;
    }

    struct TransferReleasedAssetToOtherModuleInfo {
        address token;
        uint256 amountX18;
        uint8 moduleIndex;
    }

    struct TransferUnLockAssetToOtherModuleInfo {
        uint64 index;
        uint256 amountX18;
        uint8 moduleIndex;
    }

    struct TreasuryLinearReleaseConfig {
        uint256 startReleaseBlockHeight;
        uint256 duration;
        uint256 amountPreRound;
    }

    struct TreasuryStaticReleaseConfig {
        uint256[] releaseBlockHeight;
        uint256[] releaseAmount;
    }
}
