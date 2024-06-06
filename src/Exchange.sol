// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IExchange.sol";
import "./interfaces/IUserManager.sol";
import "./interfaces/ILPManager.sol";
import "./interfaces/ITreasuryManager.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";

contract Exchange is
    IExchange,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SignedMath for int256;

    address public syncServer;
    address[] public signerList;
    uint8 public threshold;

    mapping(uint64 => address) public otherModuleAddress;

    // Map<aid, Map<symbolIndex, position>>
    mapping(uint64 => mapping(uint64 => int256)) public holdPositions;

    // other check
    bytes32 public preHash; // last commit hash
    bytes32 public secPreHash; // pre pre commit hash
    mapping(bytes32 => bool) public processedPreHash;

    uint64 public action2PreRequestId; //
    mapping(uint64 => bool) public processedAction2RequestId;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address syncServer_,
        address[] memory signerList_,
        uint8 threshold_
    ) public initializer {
        require(initialOwner != address(0x0), "invalid initial owner");
        require(signerList_.length > 0, "invalid signer list");
        require(threshold_ <= signerList_.length, "invalid threshold");
        require(syncServer_ != address(0x0), "invalid sync server address");

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        otherModuleAddress[MODULE_INDEX_EXCHANGE] = address(this);
        syncServer = syncServer_;
        signerList = signerList_;
        threshold = threshold_;
    }

    receive() external payable {}

    /// @dev process all action that will change user balance
    function batchProcess(
        bytes32 _preHash,
        bytes[] calldata transactions
    ) external onlySyncServer returns (bytes32) {
        if (preHash != _preHash) {
            revert PreHashNotMatch(preHash, _preHash);
        }

        if (processedPreHash[preHash]) {
            revert DuplicatePreHash(preHash);
        }

        processedPreHash[preHash] = true;

        bytes32 digest = keccak256(abi.encode(preHash));
        for (uint256 index = 0; index < transactions.length; index++) {
            digest = keccak256(abi.encodePacked(digest, transactions[index]));
        }

        // process user position change
        processPositionChange(transactions);

        // porcess user balance change
        IUserManager(otherModuleAddress[MODULE_INDEX_USER]).batchProcess(
            transactions
        );

        (secPreHash, preHash) = (preHash, digest);
        emit BatchProcessPreHashChange(preHash);

        return digest;
    }

    /// @dev action will not change user balance
    function batchProcessAction2(
        uint64 preRequestId,
        uint64 requestId,
        bytes[] calldata transactions
    ) external onlySyncServer {
        if (action2PreRequestId != preRequestId) {
            revert PreRequestIdNotMatch(action2PreRequestId, preRequestId);
        }

        if (processedAction2RequestId[requestId]) {
            revert DuplicateRequestId(requestId);
        }
        processedAction2RequestId[requestId] = true;

        uint256 toLPCount = 0;
        uint256[] memory toLPData = new uint256[](transactions.length);

        uint256 toUserCount = 0;
        uint256[] memory toUserData = new uint256[](transactions.length);

        uint256 toTreasuryCount = 0;
        uint256[] memory toTreasuryData = new uint256[](transactions.length);

        for (uint256 index = 0; index < transactions.length; index++) {
            Action2 action = Action2(uint8(transactions[index][0]));

            if (
                action == Action2.addNewPool ||
                action == Action2.updatePoolConfig ||
                action == Action2.updatePoolSharePrice ||
                action == Action2.redeemPoolShare
            ) {
                toLPData[toLPCount++] = index;
            } else if (action == Action2.reBalance) {
                toUserData[toUserCount++] = index;
            } else if (action == Action2.addTreasuryLockConfig) {
                toTreasuryData[toTreasuryCount++] = index;
            } else if (action == Action2.processTreasuryReleasedAsset) {
                toTreasuryData[toTreasuryCount++] = index;
            } else if (action == Action2.processTreasuryUnLockAsset) {
                toTreasuryData[toTreasuryCount++] = index;
            } else if (
                action == Action2.transferTreasuryReleasedAssetToOtherModule
            ) {
                toTreasuryData[toTreasuryCount++] = index;
            } else if (
                action == Action2.transferTreasuryUnLockAssetToOtherModule
            ) {
                toTreasuryData[toTreasuryCount++] = index;
            }
        }

        if (toLPCount > 0) {
            ILPManager(otherModuleAddress[MODULE_INDEX_LP]).batchProcessAction2(
                getTargetTxs(transactions, toLPCount, toLPData)
            );
        } else if (toUserCount > 0) {
            IUserManager(otherModuleAddress[MODULE_INDEX_USER])
                .batchProcessAction2(
                    getTargetTxs(transactions, toUserCount, toUserData)
                );
        } else if (toTreasuryCount > 0) {
            ITreasuryManager(otherModuleAddress[MODULE_INDEX_TREASURY])
                .batchProcessAction2(
                    getTargetTxs(transactions, toTreasuryCount, toTreasuryData)
                );
        }

        action2PreRequestId = requestId;
    }

    function processPositionChange(bytes[] calldata transactions) private {
        for (uint256 i = 0; i < transactions.length; i++) {
            bytes calldata data = transactions[i];
            Action action = Action(uint8(data[0]));

            if (action == Action.matchOrders) {
                processMatchOrders(data[1:]);
            } else if (action == Action.matchOrderAMM) {
                processMatchOrderAMM(data[1:]);
            } else if (action == Action.liquidate) {
                processLiquidate(data[1:]);
            }
        }
    }

    function processMatchOrders(
        bytes calldata data
    ) private returns (bool success) {
        MatchOrdersInfo memory info = abi.decode(data, (MatchOrdersInfo));
        MatchOrderInfo memory maker = info.maker;
        MatchOrderInfo memory taker = info.taker;

        maker.side == OrderSide.long
            ? holdPositions[maker.aid][info.symbolIndex] += maker.qty
            : holdPositions[maker.aid][info.symbolIndex] -= maker.qty;

        taker.side == OrderSide.long
            ? holdPositions[taker.aid][info.symbolIndex] += taker.qty
            : holdPositions[taker.aid][info.symbolIndex] -= taker.qty;

        emit MatchOrders(
            info.symbolIndex,
            info.taker.uid,
            info.taker.amountX18,
            info.taker.qty,
            info.taker.fee,
            info.maker.uid,
            info.maker.amountX18,
            info.maker.qty,
            info.maker.fee
        );

        return true;
    }

    function processMatchOrderAMM(
        bytes calldata data
    ) private returns (bool success) {
        MatchOrderAMMInfo memory info = abi.decode(data, (MatchOrderAMMInfo));
        MatchOrderInfo memory user = info.user;
        AmmMatchInfo memory amm = info.amm;

        user.side == OrderSide.long
            ? holdPositions[user.aid][info.symbolIndex] += user.qty
            : holdPositions[user.aid][info.symbolIndex] -= user.qty;

        amm.side == OrderSide.long
            ? holdPositions[info.poolIndex][info.symbolIndex] += amm.qty
            : holdPositions[info.poolIndex][info.symbolIndex] -= amm.qty;

        emit MatchOrderAMM(
            info.symbolIndex,
            info.userIsMaker,
            info.user.uid,
            info.user.amountX18,
            info.user.qty,
            info.user.fee
        );

        return true;
    }

    function processLiquidate(
        bytes calldata data
    ) private returns (bool success) {
        LiquidationInfo memory info = abi.decode(data, (LiquidationInfo));

        for (uint256 index = 0; index < info.positionList.length; index++) {
            PositionInfo memory positionInfo = info.positionList[index];
            if (
                holdPositions[positionInfo.aid][positionInfo.symbolIndex]
                    .abs() != positionInfo.qty.abs()
            ) {
                revert UserPositionNotEqual(
                    positionInfo.aid,
                    positionInfo.symbolIndex,
                    positionInfo.qty,
                    holdPositions[positionInfo.aid][positionInfo.symbolIndex]
                );
            }

            holdPositions[positionInfo.receivePoolIndex][
                positionInfo.symbolIndex
            ] += holdPositions[positionInfo.aid][positionInfo.symbolIndex];
            holdPositions[positionInfo.aid][positionInfo.symbolIndex] = 0;
        }

        emit Liquidate(info.aid);
        return true;
    }

    function getTargetTxs(
        bytes[] calldata transactions,
        uint256 wantTxCount,
        uint256[] memory wantTxIndexList
    ) internal pure returns (bytes[] memory result) {
        result = new bytes[](wantTxCount);

        for (uint256 index = 0; index < wantTxCount; index++) {
            result[index] = transactions[wantTxIndexList[index]];
        }

        return result;
    }

    // ==================== manager area ====================
    function modifyOtherModuleAddress(
        uint64 moduleIndex,
        address _newAddress,
        bytes[] calldata signList
    )
        external
        onlyMulSign(keccak256(abi.encode(moduleIndex, _newAddress)), signList)
    {
        if (otherModuleAddress[moduleIndex] == address(0x0)) {
            otherModuleAddress[moduleIndex] = _newAddress;
        }
    }

    modifier onlySyncServer() {
        if (msg.sender != syncServer) {
            revert OnlySyncServerCanCall();
        }
        _;
    }

    modifier onlyMulSign(bytes32 data, bytes[] calldata signList) {
        if (signList.length != signerList.length) {
            revert NeedMulSign();
        }

        uint8 cnt = 0;
        for (uint256 i = 0; i < signList.length; i++) {
            if (signList[i].length == 0) {
                continue;
            }

            if (_verify(data, signList[i], signerList[i])) {
                cnt++;
            }
        }

        if (cnt < threshold) {
            revert NeedMulSign();
        }
        _;
    }

    // ==================== upgrade use ====================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // ==================== utils ====================
    function _verify(
        bytes32 data,
        bytes memory signature,
        address account
    ) internal pure returns (bool) {
        return data.toEthSignedMessageHash().recover(signature) == account;
    }
}
