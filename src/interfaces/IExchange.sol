// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "./IOffChainStruct.sol";

interface IExchange is IOffChainStruct {
    event BatchProcessPreHashChange(bytes32 preHash);

    event MatchOrders(
        uint256 tokenPairIndex,
        uint64 takerUid,
        uint256 takerChangedamountX18,
        int256 takerQty,
        int256 takerFee,
        uint64 makerUid,
        uint256 makerChangedamountX18,
        int256 makerQty,
        int256 makerFee
    );

    event MatchOrderAMM(
        uint256 tokenPairIndex,
        bool isMaker,
        uint64 uid,
        uint256 changedamountX18,
        int256 qty,
        int256 fee
    );

    event Liquidate(uint64 aid);

    event ClaimProfit();

    function batchProcess(
        bytes32 preHash,
        bytes[] calldata transactions
    ) external returns (bytes32);

    function batchProcessAction2(
        uint64 preRequestId,
        uint64 requestId,
        bytes[] calldata transactions
    ) external;

    function modifyOtherModuleAddress(
        uint64 moduleIndex,
        address _newAddress,
        bytes[] calldata signList
    ) external;

    function emergencyStopWithdraw(uint64 moduleIndex) external;

    function startWithdraw(
        uint64 moduleIndex,
        uint256 nonce,
        bytes[] calldata signList
    ) external;
}
