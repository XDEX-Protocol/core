// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// common errors
error OnlySyncServerCanCall();

error OnlyManagerCanCall();

error OnlyExchangeCanCall();

error OnlyUserManagerCanCall();

error NeedMulSign();

error VaultNotInit();

error TokenNotSupport(address token);

error InvalidDataLength();

error ModuleNotInit(uint64 moduleIndex);

// exchange errors
error PreHashNotMatch(bytes32 want, bytes32 has);

error DuplicatePreHash(bytes32 preHash);

error PreRequestIdNotMatch(uint64 want, uint64 has);

error DuplicateRequestId(uint64 requestId);

error UserPositionNotEqual(
    uint64 aid,
    uint64 symbolIndex,
    int256 wantQty,
    int256 hasQty
);

// user manager errors
error InvalidDepositAddress(address from);

error InvalidOrderID(uint64 orderId);

error NotPreparedWithdrawlOrder(uint64 orderId);

error SettleAmountNotEqual();

error SettleAmountCannotLessThanZero();

error NotSupportSettleWithdrawFee();

error InsufficientFrozenAmount();

error UidNotExist(uint64 uid);

error AidNotExist(uint64 aid);

error UidAndAddressNotMatch(
    uint64 uid,
    address newAddress,
    address alreadyExist
);

error UidAndAidNotMatch(uint64 uid, uint64 aid);

error WithdrawOrderAlreadyProcessed(uint64 orderId);

error DepositOrderAlreadyProcessed(uint64 orderId);

error InsufficientBalance(
    uint64 uid,
    uint64 aid,
    address token,
    uint256 requireBalance
);

error TicketSideCannotSame();

error InvalidTicketFee();

// lp manager errors

error PoolExist(uint64 poolIndex);

error PoolNotExist(uint64 poolIndex);

error InvalidSharePrice();

error InvalidBuyerAddress(address from);

error AmountTooSmall();

error AmountLargeThanPoolMaxCanDeposit();

error AmountLargeThanUserMaxCanDeposit();

error RedeemRequestAlreadyProcessed(uint64 requestId);

error PoolIsFull();

// treasury manager errors
error InvalidLockAmount();

error DuplicateLockConfigIndex(uint64 index);

error InvalidLockConfig();

error LockTypeNotSupport();

error InsufficientFreeAssetAmount(
    address asset,
    uint256 currentSum,
    uint256 want,
    uint256 locked,
    uint256 released
);

error InsufficientUnlockAsset(address token, uint256 want, uint256 has);
