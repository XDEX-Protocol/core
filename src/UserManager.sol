// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IERC20Decimals.sol";
import "./interfaces/IUserManager.sol";
import "./interfaces/ILPManager.sol";
import "./interfaces/ITreasuryManager.sol";
import "./interfaces/IVault.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";
import "./utils/EmergencyStop.sol";
import "./libraries/X18Helper.sol";

contract UserManager is
    IUserManager,
    EmergencyStop,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;
    using SignedMath for int256;
    using SafeCast for int256;
    using SafeCast for uint256;

    address public vaultAddress;
    mapping(uint64 => address) public otherModuleAddress;

    address public platformSigner;
    address[] public signerList;
    uint public threshold;
    address withdrawFeeDesc;
    address platformIncomeDesc;

    mapping(address => bool) public availableToken;

    // user info
    mapping(uint64 => uint64) public aidUidMap; // aid => uid
    mapping(uint64 => address) public addressMap; // all user uid, include system uid
    mapping(uint64 => mapping(address => int256)) public balanceMap; // user balance, can't less than zero

    // withdraw/deposit info
    mapping(uint64 => PrepareWithdrawInfo) public prepareWithdrawOrderMap;
    mapping(uint64 => mapping(address => uint256)) public frozenUserAsset; // user asset that is frozen
    mapping(uint64 => bool) public processedOrder;

    // system aid info
    uint64 public platformIncomeAID;
    uint64 public withdrawFeeAID; //
    mapping(uint64 => uint64) public moduleBalanceAIDMap; // Map<moduleIndex, moduleAID> other module balance in exchange, like treasury, stake ..., lp pool not here, is in poolBalanceAIDMap
    mapping(uint64 => uint64) public poolBalanceAIDMap; // Map<poolIndex, poolAID> pool balance in exchange, when reBalance, target pool balance will change to zero and asset token will transfer to lp vault

    // system profit info
    mapping(uint64 => mapping(address => int256)) public tradeFeeMap; // trade fee info, Map<(poolIndex),  Map<token, tradeFee>>
    mapping(uint64 => mapping(address => int256)) public liquidationProfitMap; // not used liquidation profit info, Map<(poolIndex),  Map<token, amountX18>>
    mapping(uint64 => mapping(address => int256)) public tradeProfitMap; // trade profit info, Map<(poolIndex),  Map<token, profit>>

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address[] memory signerList_,
        uint8 threshold_,
        address exchangeAddress,
        uint64 withdrawFeeAID_,
        uint64 platformIncomeAID_,
        address platformSigner_,
        address withdrawFeeDesc_,
        address platformIncomeDesc_
    ) public initializer {
        require(initialOwner != address(0x0), "invalid initial owner");
        require(signerList_.length > 0, "invalid mul signer");
        require(threshold <= signerList_.length, "invalid mul signer");
        require(exchangeAddress != address(0x0), "invalid exchange address");
        require(withdrawFeeAID_ != 0, "invalid withdraw fee aid");
        require(platformIncomeAID_ != 0, "invalid platform income aid");
        require(platformSigner_ != address(0x0), "invalid platform signer");
        require(withdrawFeeDesc_ != address(0x0), "invalid withdraw fee desc");
        require(
            platformIncomeDesc_ != address(0x0),
            "invalid platform income desc"
        );

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        SetupEmergencyStop(exchangeAddress, signerList_, threshold_);

        signerList = signerList_;
        threshold = threshold_;
        otherModuleAddress[MODULE_INDEX_EXCHANGE] = exchangeAddress;
        withdrawFeeAID = withdrawFeeAID_;
        platformIncomeAID = platformIncomeAID_;
        platformSigner = platformSigner_;
        withdrawFeeDesc = withdrawFeeDesc_;
        platformIncomeDesc = platformIncomeDesc_;
    }

    receive() external payable {}

    function deposit(address from, address token, uint256 amount) external {
        if (from != msg.sender) {
            revert InvalidDepositAddress(from);
        }
        if (vaultAddress == address(0x0)) {
            revert VaultNotInit();
        }

        if (!availableToken[token]) {
            revert TokenNotSupport(token);
        }

        IERC20(token).safeTransferFrom(from, vaultAddress, amount);
        uint256 amountX18 = X18Helper.toX18(amount, token);

        emit UserDeposit(from, token, amountX18);
    }

    function batchProcess(bytes[] calldata actionData) external onlyExchange {
        for (uint256 index = 0; index < actionData.length; index++) {
            processDetail(actionData[index]);
        }
    }

    function batchProcessAction2(
        bytes[] calldata actionData
    ) external onlyExchange {
        for (uint256 index = 0; index < actionData.length; index++) {
            bytes calldata data = actionData[index];
            Action2 action = Action2(uint8(data[0]));

            if (action == Action2.reBalance) {
                reBalance(data);
            }
        }
    }

    function withdrawFeeIncome(
        address token,
        uint256 amount
    ) external onlyPlatform {
        userBalanceMustEnough(withdrawFeeAID, token, amount);

        balanceMap[withdrawFeeAID][token] -= amount.toInt256();

        IVault(vaultAddress).withdraw(platformIncomeDesc, token, amount);
    }

    function withdrawPlatformIncome(
        address token,
        uint256 amount
    ) external onlyPlatform {
        userBalanceMustEnough(platformIncomeAID, token, amount);

        balanceMap[platformIncomeAID][token] -= amount.toInt256();

        IVault(vaultAddress).withdraw(withdrawFeeDesc, token, amount);
    }

    function getVaultAddress() external view returns (address) {
        return vaultAddress;
    }

    function processDetail(bytes calldata data) internal {
        Action action = Action(uint8(data[0]));

        if (action == Action.depositConfirm) {
            processActionDepositConfirm(data);
        } else if (action == Action.prepareWithdraw) {
            processActionPrepareWithdraw(data);
        } else if (action == Action.executeWithdraw) {
            processActionExecuteWithdraw(data);
        } else if (action == Action.cancelWithdraw) {
            processActionCancelWithdraw(data);
        } else if (action == Action.matchOrders) {
            processActionMatchOrders(data);
        } else if (action == Action.matchOrderAMM) {
            processActionMathOrderAMM(data);
        } else if (action == Action.liquidate) {
            processActionLiquidate(data);
        } else if (action == Action.fundingSettle) {
            processActionFundingSettle(data);
        } else if (action == Action.tradeProfitSettle) {
            processActionTradeProfitSettle(data);
        } else if (action == Action.withdrawFeeSettle) {
            revert NotSupportSettleWithdrawFee();
        } else if (action == Action.activitySettle) {
            processActionActivitySettle(data);
        } else if (action == Action.frozenUserAsset) {
            processActionFrozenUserAsset(data);
        } else if (action == Action.unfrozenUserAsset) {
            processActionUnFrozenUserAsset(data);
        } else if (action == Action.internalTransfer) {
            processActionInternalTransfer(data);
        }
    }

    function processActionDepositConfirm(bytes calldata data) internal {
        DepositConfirmInfo memory info = abi.decode(
            data[1:],
            (DepositConfirmInfo)
        );
        if (addressMap[info.uid] == address(0x0)) {
            addressMap[info.uid] = info.from;
        }
        if (aidUidMap[info.aid] == 0) {
            aidUidMap[info.aid] = info.uid;
        }
        if (info.orderId == 0) {
            revert InvalidOrderID(info.orderId);
        }

        depositOrderMustNotProcessed(info.orderId);
        uidAddressMustMatch(info.uid, info.from);
        uidAidMustBind(info.uid, info.aid);

        balanceMap[info.aid][info.token] += info.amountX18.toInt256();

        emit UserDepositConfirmed(
            info.uid,
            info.aid,
            info.from,
            info.token,
            info.amountX18
        );
    }

    function processActionPrepareWithdraw(
        bytes calldata data
    ) internal withdrawIsEnable {
        PrepareWithdrawInfo memory info = abi.decode(
            data[1:],
            (PrepareWithdrawInfo)
        );
        if (info.orderId == 0) {
            revert InvalidOrderID(info.orderId);
        }

        withdrawOrderMustNotProcessed(info.orderId);
        uidAidMustBind(info.uid, info.aid);
        userBalanceMustEnough(info.aid, info.token, info.amountX18 + info.fee);

        balanceMap[info.aid][info.token] -= (info.amountX18 + info.fee)
            .toInt256();
        prepareWithdrawOrderMap[info.orderId] = info;

        emit UserWithdrawFinishPrepare(info.orderId);
    }

    function processActionExecuteWithdraw(
        bytes calldata data
    ) internal withdrawIsEnable {
        ExecuteWithdrawInfo memory info = abi.decode(
            data[1:],
            (ExecuteWithdrawInfo)
        );

        PrepareWithdrawInfo memory orderInfo = prepareWithdrawOrderMap[
            info.orderId
        ];
        if (orderInfo.orderId != info.orderId) {
            revert NotPreparedWithdrawlOrder(info.orderId);
        }

        withdrawOrderProcessed(info.orderId);

        balanceMap[withdrawFeeAID][orderInfo.token] += orderInfo.fee.toInt256();

        uint256 amountInReal = X18Helper.fromX18ToNormalDecimal(
            orderInfo.amountX18,
            orderInfo.token
        );

        IVault(vaultAddress).withdraw(
            addressMap[orderInfo.uid],
            orderInfo.token,
            amountInReal
        );

        emit UserWithdrawProcessed(
            orderInfo.orderId,
            orderInfo.uid,
            orderInfo.aid,
            addressMap[orderInfo.uid],
            orderInfo.token,
            orderInfo.amountX18,
            orderInfo.fee,
            orderInfo.userSign
        );
    }

    function processActionCancelWithdraw(bytes calldata data) internal {
        CancelWithdrawInfo memory info = abi.decode(
            data[1:],
            (CancelWithdrawInfo)
        );

        PrepareWithdrawInfo memory orderInfo = prepareWithdrawOrderMap[
            info.orderId
        ];
        if (orderInfo.orderId != info.orderId) {
            revert NotPreparedWithdrawlOrder(info.orderId);
        }

        withdrawOrderProcessed(info.orderId);

        balanceMap[orderInfo.aid][orderInfo.token] += (orderInfo.amountX18 +
            orderInfo.fee).toInt256();

        emit UserWithdrawCanceled(info.orderId);
    }

    function processActionMatchOrders(bytes calldata data) internal {
        MatchOrdersInfo memory info = abi.decode(data[1:], (MatchOrdersInfo));

        uidMustExist(info.maker.uid);
        uidAidMustBind(info.maker.uid, info.maker.aid);

        uidMustExist(info.taker.uid);
        uidAidMustBind(info.taker.uid, info.taker.aid);

        ticketMustVaild(info);

        tradeFeeMap[info.poolIndex][info.token] += info.feeProfit;
        changeBalaceByOrderInfo(info.ticketId, info.token, info.maker);
        changeBalaceByOrderInfo(info.ticketId, info.token, info.taker);
    }

    function processActionMathOrderAMM(bytes calldata data) internal {
        MatchOrderAMMInfo memory info = abi.decode(
            data[1:],
            (MatchOrderAMMInfo)
        );

        uidMustExist(info.user.uid);
        uidAidMustBind(info.user.uid, info.user.aid);

        ammTicketMustVaild(info);

        tradeFeeMap[info.poolIndex][info.token] += info.feeProfit;
        changeBalaceByOrderInfo(info.ticketId, info.token, info.user);
        changeProfitByOrderInfo(info.token, info.poolIndex, info.amm);
    }

    function processActionLiquidate(bytes calldata data) internal {
        LiquidationInfo memory info = abi.decode(data[1:], (LiquidationInfo));

        aidMustExist(info.aid);

        for (uint256 index = 0; index < info.balanceList.length; index++) {
            BalanceInfo memory balanceInfo = info.balanceList[index];

            balanceMap[balanceInfo.aid][balanceInfo.token] -= balanceInfo
                .amountX18;
            tradeProfitMap[balanceInfo.receivePoolIndex][
                balanceInfo.token
            ] += balanceInfo.amountX18;
        }

        for (uint256 index = 0; index < info.balanceList.length; index++) {
            BalanceInfo memory balanceInfo = info.balanceList[index];

            if (balanceMap[balanceInfo.aid][balanceInfo.token] != 0) {
                revert InsufficientBalance(
                    aidUidMap[balanceInfo.aid],
                    balanceInfo.aid,
                    balanceInfo.token,
                    balanceMap[balanceInfo.aid][balanceInfo.token].abs()
                );
            }
        }
    }

    function processActionFundingSettle(bytes calldata data) internal {
        FundingFeeInfo memory info = abi.decode(data[1:], (FundingFeeInfo));

        if (info.poolIndex != 0) {
            // change profit account balance
            tradeProfitMap[info.poolIndex][info.token] += info.fee;
        } else {
            aidMustExist(info.aid);
            balanceMap[info.aid][info.token] += info.fee;

            if (balanceMap[info.aid][info.token] < 0) {
                revert InsufficientBalance(
                    aidUidMap[info.aid],
                    info.aid,
                    info.token,
                    info.fee.abs()
                );
            }
        }

        emit UserFundingFeeSettled(info.symbolIndex, info.time, info.token);
    }

    function processActionTradeProfitSettle(bytes calldata data) internal {
        TradeProfitSettleList memory settleInfoList = abi.decode(
            data[1:],
            (TradeProfitSettleList)
        );

        for (uint256 i = 0; i < settleInfoList.list.length; i++) {
            TradeProfitSettleInfo memory info = settleInfoList.list[i];

            if (info.settleType == ProfitSettleType.AllocPnlToLP) {
                // from is pool index
                // to is pool index
                tradeProfitMap[info.fromId][info.token] -= info
                    .amount
                    .toInt256();
                balanceMap[info.toId][info.token] += info.amount.toInt256();
            } else if (info.settleType == ProfitSettleType.TradeFeeToPlatform) {
                // from is pool index
                // to is platform aid
                tradeFeeMap[info.fromId][info.token] -= info.amount.toInt256();
                balanceMap[info.toId][info.token] += info.amount.toInt256();
            } else if (info.settleType == ProfitSettleType.TradeFeeToLP) {
                // from is pool index
                // to is pool index
                tradeFeeMap[info.fromId][info.token] -= info.amount.toInt256();
                balanceMap[info.toId][info.token] += info.amount.toInt256();
            } else if (info.settleType == ProfitSettleType.TradeFeeToTreasury) {
                // from is pool index
                // to is treasury aid
                tradeFeeMap[info.fromId][info.token] -= info.amount.toInt256();
                balanceMap[info.toId][info.token] += info.amount.toInt256();
            }
        }
    }

    function processActionActivitySettle(bytes calldata data) internal {
        ActivitySettleInfo memory info = abi.decode(
            data[1:],
            (ActivitySettleInfo)
        );

        if (info.changedAmountX18 < 0) {
            userBalanceMustEnough(
                info.toAId,
                info.token,
                info.changedAmountX18.abs()
            );
        } else {
            userBalanceMustEnough(
                info.fromAId,
                info.token,
                info.changedAmountX18.toUint256()
            );
        }

        balanceMap[info.fromAId][info.token] -= info.changedAmountX18;
        balanceMap[info.toAId][info.token] += info.changedAmountX18;

        emit ActivitySettled(
            info.activityId,
            info.token,
            info.fromAId,
            info.toAId,
            info.changedAmountX18,
            info.reason
        );
    }

    function processActionFrozenUserAsset(bytes calldata data) internal {
        FrozenUserAsset memory info = abi.decode(data[1:], (FrozenUserAsset));

        aidMustExist(info.aid);
        uidAidMustBind(info.uid, info.aid);
        userBalanceMustEnough(info.aid, info.token, info.amountX18);

        balanceMap[info.aid][info.token] -= info.amountX18.toInt256();
        frozenUserAsset[info.aid][info.token] += info.amountX18;

        emit UserAssetFrozen(
            info.uid,
            info.aid,
            info.token,
            info.amountX18,
            info.reason
        );
    }

    function processActionUnFrozenUserAsset(bytes calldata data) internal {
        UnFrozenUserAsset memory info = abi.decode(
            data[1:],
            (UnFrozenUserAsset)
        );

        aidMustExist(info.aid);
        uidAidMustBind(info.uid, info.aid);

        if (frozenUserAsset[info.aid][info.token] < info.amountX18) {
            revert InsufficientFrozenAmount();
        }

        frozenUserAsset[info.aid][info.token] -= info.amountX18;
        balanceMap[info.aid][info.token] += info.amountX18.toInt256();

        emit UserAssetUnFrozen(
            info.uid,
            info.aid,
            info.token,
            info.amountX18,
            info.reason
        );
    }

    function processActionInternalTransfer(bytes calldata data) internal {
        InternalTransferInfo memory info = abi.decode(
            data[1:],
            (InternalTransferInfo)
        );

        aidMustExist(info.fromAid);
        uidAidMustBind(info.fromUid, info.fromAid);

        aidMustExist(info.toAid);
        uidAidMustBind(info.toUid, info.toAid);

        userBalanceMustEnough(info.fromAid, info.token, info.amountX18);

        balanceMap[info.fromAid][info.token] -= info.amountX18.toInt256();
        balanceMap[info.toAid][info.token] += info.amountX18.toInt256();

        emit InternalTransfer(
            info.transferType,
            info.fromUid,
            info.fromAid,
            info.toUid,
            info.toAid,
            info.token,
            info.amountX18,
            info.reason
        );
    }

    function reBalance(bytes calldata data) internal {
        ReBalanceInfoList memory reBalanceInfo = abi.decode(
            data[1:],
            (ReBalanceInfoList)
        );

        // first reBalance treasury
        uint64 treasuryAID = moduleBalanceAIDMap[MODULE_INDEX_TREASURY];
        int256 treasuryBalance = balanceMap[treasuryAID][reBalanceInfo.token];
        if (treasuryBalance != 0) {
            balanceMap[treasuryAID][reBalanceInfo.token] = 0; // set treasury balance to zero, because treasury vault success trans token to user vault

            uint256 amountInReal = X18Helper.fromX18ToNormalDecimal(
                treasuryBalance.abs(),
                reBalanceInfo.token
            );

            if (treasuryBalance < 0) {
                // treasury should give user manager vault some token
                IReBalance(otherModuleAddress[MODULE_INDEX_TREASURY])
                    .reBalanceToUserManager(reBalanceInfo.token, amountInReal);
            } else {
                // user manager should give treasury vault some token
                IVault(vaultAddress).withdraw(
                    ITreasuryManager(otherModuleAddress[MODULE_INDEX_TREASURY])
                        .getVaultAddress(),
                    reBalanceInfo.token,
                    amountInReal
                );
            }
        }

        for (uint256 i = 0; i < reBalanceInfo.settlePoolIndexList.length; i++) {
            uint64 poolIndex = reBalanceInfo.settlePoolIndexList[i];
            uint64 poolAID = poolBalanceAIDMap[poolIndex];
            if (poolAID == 0) {
                poolAID = poolIndex;
            }

            int256 lpBalance = balanceMap[poolAID][reBalanceInfo.token];
            if (lpBalance != 0) {
                balanceMap[poolAID][reBalanceInfo.token] = 0;

                uint256 amountInReal = X18Helper.fromX18ToNormalDecimal(
                    lpBalance.abs(),
                    reBalanceInfo.token
                );

                if (lpBalance < 0) {
                    // lp should give user manager vault some token
                    IReBalance(otherModuleAddress[MODULE_INDEX_LP])
                        .reBalanceToUserManager(
                            reBalanceInfo.token,
                            amountInReal
                        );
                } else {
                    // user manager should give lp vault some token
                    IVault(vaultAddress).withdraw(
                        ILPManager(otherModuleAddress[MODULE_INDEX_LP])
                            .getVaultAddress(),
                        reBalanceInfo.token,
                        amountInReal
                    );
                }
            }
        }
    }

    // ==================== manager area ====================

    function setVaultAddress(address _vaultAddress) external onlyOwner {
        if (vaultAddress == address(0x0)) {
            vaultAddress = _vaultAddress;
        }
    }

    function addAvailableToken(address token) external onlyOwner {
        availableToken[token] = true;
    }

    function removeAvailableToken(address token) external onlyExchange {
        availableToken[token] = false;
    }

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

    modifier withdrawIsEnable() {
        if (!_isWithdrawalAllowed()) {
            revert WithdrawStopped();
        }
        _;
    }

    modifier onlyExchange() {
        if (msg.sender != otherModuleAddress[MODULE_INDEX_EXCHANGE]) {
            revert OnlyExchangeCanCall();
        }

        _;
    }

    modifier onlyPlatform() {
        if (msg.sender != platformSigner) {
            revert OnlyManagerCanCall();
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

    function _verify(
        bytes32 data,
        bytes memory signature,
        address account
    ) internal pure returns (bool) {
        return data.toEthSignedMessageHash().recover(signature) == account;
    }

    // ==================== upgrade use ====================

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    // ==================== utils ====================
    function withdrawOrderProcessed(uint64 orderId) private {
        processedOrder[orderId] = true;
        prepareWithdrawOrderMap[orderId] = PrepareWithdrawInfo(
            0,
            0,
            0,
            address(0),
            0,
            0,
            bytes("")
        );
    }

    function depositOrderMustNotProcessed(uint64 orderId) private {
        if (processedOrder[orderId]) {
            revert DepositOrderAlreadyProcessed(orderId);
        }
        processedOrder[orderId] = true;
    }

    function changeBalaceByOrderInfo(
        uint64 ticketId,
        address token,
        MatchOrderInfo memory info
    ) private {
        balanceMap[info.aid][token] -= info.fee;
        balanceMap[info.aid][token] += info.pnl;

        emit UserTradeSettled(
            ticketId,
            token,
            info.aid,
            info.fee,
            info.pnl,
            balanceMap[info.aid][token]
        );
    }

    function changeProfitByOrderInfo(
        address token,
        uint64 poolIndex,
        AmmMatchInfo memory info
    ) private {
        tradeProfitMap[poolIndex][token] -= info.fee;
        tradeProfitMap[poolIndex][token] += info.pnl;
    }

    function uidMustExist(uint64 uid) private view {
        if (addressMap[uid] == address(0x0)) {
            revert UidNotExist(uid);
        }
    }

    function aidMustExist(uint64 aid) private view {
        if (aidUidMap[aid] == 0) {
            revert AidNotExist(aid);
        }
    }

    function uidAddressMustMatch(uint64 uid, address from) private view {
        if (addressMap[uid] != from) {
            revert UidAndAddressNotMatch(uid, from, addressMap[uid]);
        }
    }

    function uidAidMustBind(uint64 uid, uint64 aid) private view {
        if (aidUidMap[aid] != uid) {
            revert UidAndAidNotMatch(uid, aid);
        }
    }

    function withdrawOrderMustNotProcessed(uint64 orderId) private view {
        if (
            processedOrder[orderId] ||
            prepareWithdrawOrderMap[orderId].orderId != 0
        ) {
            revert WithdrawOrderAlreadyProcessed(orderId);
        }
    }

    function userBalanceMustEnough(
        uint64 aid,
        address token,
        uint256 requireBalance
    ) private view {
        if (balanceMap[aid][token] < requireBalance.toInt256()) {
            revert InsufficientBalance(
                aidUidMap[aid],
                aid,
                token,
                requireBalance
            );
        }
    }

    function isAvailablePoolIndex(
        uint64 poolIndex
    ) private view returns (bool) {
        return
            ILPManager(otherModuleAddress[MODULE_INDEX_LP]).availablePoolIndex(
                poolIndex
            );
    }

    function ticketMustVaild(MatchOrdersInfo memory ticketInfo) private view {
        if (ticketInfo.maker.side == ticketInfo.taker.side) {
            revert TicketSideCannotSame();
        }

        // total fee should equal
        if (ticketInfo.feeProfit < 0) {
            revert InvalidTicketFee();
        }

        if (
            ticketInfo.feeProfit != ticketInfo.maker.fee + ticketInfo.taker.fee
        ) {
            revert InvalidTicketFee();
        }

        userBalanceMustEnough(
            ticketInfo.maker.aid,
            ticketInfo.token,
            (ticketInfo.maker.fee + ticketInfo.maker.pnl).abs()
        );

        userBalanceMustEnough(
            ticketInfo.taker.aid,
            ticketInfo.token,
            (ticketInfo.taker.fee + ticketInfo.taker.pnl).abs()
        );
    }

    function ammTicketMustVaild(
        MatchOrderAMMInfo memory ticketInfo
    ) private view {
        if (ticketInfo.user.side == ticketInfo.amm.side) {
            revert TicketSideCannotSame();
        }

        // total fee should equal
        if (ticketInfo.feeProfit < 0) {
            revert InvalidTicketFee();
        }

        if (ticketInfo.feeProfit != ticketInfo.user.fee + ticketInfo.amm.fee) {
            revert InvalidTicketFee();
        }

        userBalanceMustEnough(
            ticketInfo.user.aid,
            ticketInfo.token,
            (ticketInfo.user.fee + ticketInfo.user.pnl).abs()
        );
    }
}
