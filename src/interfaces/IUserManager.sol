// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./IOffChainStruct.sol";
import "./IEmergencyStop.sol";

interface IUserManager is IOffChainStruct, IEmergencyStop {
    event UserDeposit(address from, address token, uint256 amountX18);

    event UserDepositConfirmed(
        uint64 uid,
        uint64 aid,
        address from,
        address token,
        uint256 amountX18
    );

    event UserWithdrawFinishPrepare(bool accept, uint64 orderId);

    event UserWithdrawProcessed(
        bool accept,
        uint64 orderId,
        uint64 uid,
        uint64 aid,
        address to,
        address token,
        uint256 amountX18,
        uint256 fee,
        bytes userSign
    );

    event UserWithdrawCanceled(uint64 orderId);

    event UserTradeSettled(
        uint64 ticketId,
        address token,
        uint64 aid,
        int256 fee,
        int256 pnl,
        int256 afterChangedBalance
    );

    event UserFundingFeeSettled(uint64 symbolIndex, uint64 time, address token);

    event UserGamingSettled(
        uint64 gameOrderId,
        uint64 aid,
        address token,
        int256 changedBalance,
        int256 afterChangeBalance
    );

    event ActivitySettled(
        uint64 activityId,
        address token,
        uint64 fromAId,
        uint64 toAId,
        int256 changedAmountX18,
        string reason
    );

    event UserAssetFrozen(
        uint64 uid,
        uint64 aid,
        address token,
        uint256 amountX18,
        string reason
    );

    event UserAssetUnFrozen(
        uint64 uid,
        uint64 aid,
        address token,
        uint256 amountX18,
        string reason
    );

    event InternalTransfer(
        uint64 transferType,
        uint64 fromUid,
        uint64 fromAid,
        uint64 toUid,
        uint64 toAid,
        address token,
        uint256 amountX18,
        string reason
    );

    event TradeProfitSetted(
        address token,
        uint64[] toModuleIndexList,
        int256[] settleamountX18
    );

    function batchProcess(bytes[] calldata waitProcessData) external;

    function batchProcessAction2(bytes[] calldata waitProcessData) external;

    function modifyOtherModuleAddress(
        uint64 moduleIndex,
        address _newAddress,
        bytes[] calldata signList
    ) external;

    function setVaultAddress(address vault) external;
    function getVaultAddress() external view returns (address);
    function addAvailableToken(address token) external;
    function removeAvailableToken(address token) external;

    function withdrawFeeIncome(address token, uint256 amount) external;
}
