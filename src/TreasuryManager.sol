// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IERC20Decimals.sol";
import "./interfaces/ITreasuryManager.sol";
import "./interfaces/IUserManager.sol";
import "./interfaces/ILPManager.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IVault.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";
import "./utils/EmergencyStop.sol";
import "./utils/EmergencyWithdraw.sol";
import "./utils/RefundDeposit.sol";
import "./libraries/X18Helper.sol";

contract TreasuryManager is
    ITreasuryManager,
    EmergencyStop,
    EmergencyWithdraw,
    RefundDeposit,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SignedMath for int256;
    using SafeCast for int256;
    using SafeCast for uint256;

    address public vaultAddress;
    mapping(uint64 => address) public otherModuleAddress;

    address[] public signerList;
    uint public threshold;

    mapping(uint64 => OnChainLockConfig) public lockConfigMap; // Map<configIndex, config> 锁仓配置
    mapping(address => uint256) public totalLockedAsset; // Map<asset, amount> 总锁仓金额
    mapping(address => uint256) public totalReleasedAsset; // Map<asset, amount> 总释放量
    mapping(address => uint256) public usedUnlockAsset; // Map<asset, amount> 已使用未锁仓数量
    mapping(uint64 => uint256) public canReleaseAssetAmount; // Map<configIndex, amount> 可释放金额
    mapping(uint64 => uint256) public releasedAssetAmount; // Map<configIndex, amount> 已释放金额  链下上传分配策略
    mapping(uint64 => mapping(address => uint256))
        public userCanClaimAssetAmount; // Map<configIndex, Map<walletAddress, amount>> 配置已发放给用户的金额
    mapping(uint64 => mapping(address => uint256))
        public userClaimedAssetAmount; // Map<configIndex, Map<walletAddress, amount>> 配置已发放给用户, 用户已经领取的金额
    mapping(address => mapping(address => uint256))
        public userCanClaimUnlockAssetAmount; // Map<coinAddress, Map<walletAddress, amount>> 未锁定资产发放给用户的金额

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address[] memory signerList_,
        uint8 threshold_,
        address exchangeAddress
    ) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        signerList = signerList_;
        threshold = threshold_;
        otherModuleAddress[MODULE_INDEX_EXCHANGE] = exchangeAddress;
    }

    receive() external payable {}

    function batchProcess(
        bytes[] calldata waitProcessData
    ) external onlyExchange {}

    function batchProcessAction2(
        bytes[] calldata actionData
    ) external onlyExchange {
        for (uint256 index = 0; index < actionData.length; index++) {
            bytes calldata data = actionData[index];
            Action2 action = Action2(uint8(data[0]));

            if (action == Action2.addTreasuryLockConfig) {
                addLockConfig(data[1:]);
            } else if (action == Action2.processTreasuryReleasedAsset) {
                processReleasedAsset(data);
            } else if (action == Action2.processTreasuryUnLockAsset) {
                processUnLockAsset(data);
            } else if (
                action == Action2.transferTreasuryReleasedAssetToOtherModule
            ) {
                transferReleasedAssetToOtherModule(data);
            } else if (
                action == Action2.transferTreasuryUnLockAssetToOtherModule
            ) {
                transferUnLockAssetToOtherModule(data);
            }
        }
    }

    function claimReleasedAsset(
        uint64 index
    ) external returns (address asset, uint256 amount) {
        if (lockConfigMap[index].index != index) {
            revert InvalidLockConfig();
        }

        OnChainLockConfig memory config = lockConfigMap[index];
        asset = config.asset;
        amount = 0;

        if (userCanClaimAssetAmount[index][msg.sender] == 0) {
            return (asset, amount);
        }
        uint256 canClaimAssetAmount = userCanClaimAssetAmount[index][
            msg.sender
        ];

        if (userClaimedAssetAmount[index][msg.sender] >= canClaimAssetAmount) {
            return (asset, amount);
        }

        amount =
            canClaimAssetAmount -
            userClaimedAssetAmount[index][msg.sender];

        userClaimedAssetAmount[index][msg.sender] += amount;
        IVault(vaultAddress).withdraw(msg.sender, asset, amount);
    }

    function refreshCanReleaseAssetAmount(
        uint64[] calldata configIndexList
    ) external {
        _refreshCanReleaseAssetAmount(configIndexList);
    }

    function reBalanceToUserManager(
        address token,
        uint256 amountX18
    ) external onlyUserManager {
        uint256 amountInReal = X18Helper.fromX18ToNormalDecimal(
            amountX18,
            token
        );

        IVault(vaultAddress).withdraw(
            IUserManager(otherModuleAddress[MODULE_INDEX_USER])
                .getVaultAddress(),
            token,
            amountInReal
        );
    }

    function getVaultAddress() external view returns (address) {
        return vaultAddress;
    }

    function getAvailableAmount(
        uint64 index,
        address walletAddress
    ) external view returns (uint256 amount, address asset, uint8 decimal) {
        OnChainLockConfig memory info = lockConfigMap[index];
        amount =
            userCanClaimAssetAmount[index][walletAddress] -
            userClaimedAssetAmount[index][walletAddress];
        return (amount, info.asset, IERC20Decimals(info.asset).decimals());
    }

    function _refreshCanReleaseAssetAmount(
        uint64[] memory configIndexList
    ) private {
        for (uint256 i = 0; i < configIndexList.length; i++) {
            uint64 configIndex = configIndexList[i];

            OnChainLockConfig memory config = lockConfigMap[configIndex];

            require(config.index == configIndex, "config not exist");

            uint256 beforeCanRelease = canReleaseAssetAmount[configIndex];
            canReleaseAssetAmount[configIndex] = getCanReleaseAmount(config);

            // already release asset can't lock by same config again
            if (beforeCanRelease > canReleaseAssetAmount[configIndex]) {
                totalLockedAsset[config.asset] -= (canReleaseAssetAmount[
                    configIndex
                ] - beforeCanRelease);
            }
        }
    }

    function checkLinerRelaseConfigLegal(
        uint256 lockAmount,
        bytes memory configDetail
    ) private pure returns (bool) {
        TreasuryLinearReleaseConfig memory config = abi.decode(
            configDetail,
            (TreasuryLinearReleaseConfig)
        );
        if (lockAmount % config.amountPreRound == 0) {
            return true;
        }

        return false;
    }

    function checkStaticRelaseConfigLegal(
        uint256 lockAmount,
        bytes memory configDetail
    ) private pure returns (bool) {
        TreasuryStaticReleaseConfig memory config = abi.decode(
            configDetail,
            (TreasuryStaticReleaseConfig)
        );

        if (config.releaseBlockHeight.length != config.releaseAmount.length) {
            return false;
        }

        uint256 amount = 0;
        uint256 preReleaseHeight = 0;
        for (uint256 i = 0; i < config.releaseAmount.length; i++) {
            if (preReleaseHeight > config.releaseBlockHeight[i]) {
                return false;
            }

            preReleaseHeight = config.releaseBlockHeight[i];

            amount += config.releaseAmount[i];
        }

        if (amount == lockAmount) {
            return true;
        }

        return false;
    }

    function addLockConfig(bytes calldata data) private {
        AddTreasuryLockConfigInfo memory info = abi.decode(
            data[1:],
            (AddTreasuryLockConfigInfo)
        );
        _addLockConfig(
            info.index,
            info.lockAsset,
            info.canUpdateConfig,
            info.lockType,
            info.lockAssetAmountX18,
            info.configDetail
        );
    }

    function _addLockConfig(
        uint64 index,
        address lockAsset,
        bool canUpdateConfig,
        LockType lockType,
        uint256 lockAssetAmountX18,
        bytes memory configDetail
    ) private {
        require(vaultAddress != address(0x0), "valut address not set");

        uint256 lockAssetAmount = X18Helper.fromX18ToNormalDecimal(
            lockAssetAmountX18,
            lockAsset
        );

        if (lockAssetAmount == 0) {
            revert InvalidLockAmount();
        }
        if (lockConfigMap[index].lockAssetAmount != 0) {
            revert DuplicateLockConfigIndex(index);
        }

        lockConfigMap[index] = OnChainLockConfig(
            index,
            lockAsset,
            canUpdateConfig,
            lockType,
            lockAssetAmount,
            configDetail
        );

        if (lockType == LockType.linearRelease) {
            if (!checkLinerRelaseConfigLegal(lockAssetAmount, configDetail)) {
                revert InvalidLockConfig();
            }
        } else if (lockType == LockType.staticRelease) {
            if (!checkStaticRelaseConfigLegal(lockAssetAmount, configDetail)) {
                revert InvalidLockConfig();
            }
        } else {
            revert LockTypeNotSupport();
        }

        if (
            IERC20(lockAsset).balanceOf(vaultAddress) >=
            lockAssetAmount +
                totalLockedAsset[lockAsset] -
                totalReleasedAsset[lockAsset] -
                usedUnlockAsset[lockAsset]
        ) {
            revert InsufficientFreeAssetAmount(
                IERC20(lockAsset).balanceOf(vaultAddress),
                lockAssetAmount,
                totalLockedAsset[lockAsset],
                totalReleasedAsset[lockAsset]
            );
        }

        uint64[] memory targetConfigList = new uint64[](1);
        targetConfigList[0] = index;
        _refreshCanReleaseAssetAmount(targetConfigList);

        totalLockedAsset[lockAsset] += lockAssetAmount;

        emit NewLockConfigAdded(index, lockAsset, lockAssetAmount);
    }

    function processReleasedAsset(bytes calldata data) private {
        ProcessReleasedAssetInfo memory info = abi.decode(
            data[1:],
            (ProcessReleasedAssetInfo)
        );
        _processReleasedAsset(
            info.needAirDrop,
            info.index,
            info.recipients,
            info.amountX18List
        );
    }

    function processUnLockAsset(bytes calldata data) private {
        ProcessUnLockAssetInfo memory info = abi.decode(
            data[1:],
            (ProcessUnLockAssetInfo)
        );
        _processUnLockAsset(
            info.needAirDrop,
            info.token,
            info.recipients,
            info.amountX18List
        );
    }

    function transferUnLockAssetToOtherModule(bytes calldata data) private {
        TransferReleasedAssetToOtherModuleInfo memory info = abi.decode(
            data[1:],
            (TransferReleasedAssetToOtherModuleInfo)
        );
        _transferUnLockAssetToOtherModule(
            info.token,
            info.amountX18,
            info.moduleIndex
        );
    }

    function transferReleasedAssetToOtherModule(bytes calldata data) private {
        TransferUnLockAssetToOtherModuleInfo memory info = abi.decode(
            data[1:],
            (TransferUnLockAssetToOtherModuleInfo)
        );
        _transferReleasedAssetToOtherModule(
            info.index,
            info.amountX18,
            info.moduleIndex
        );
    }

    function _processReleasedAsset(
        bool needAirDrop,
        uint64 index,
        address[] memory recipients,
        uint256[] memory amountX18List
    ) private {
        require(lockConfigMap[index].index == index, "config not exist");
        require(
            recipients.length == amountX18List.length,
            "list length not equal"
        );
        OnChainLockConfig memory config = lockConfigMap[index];

        uint256 canReleaseAmount = getCanReleaseAmount(config);
        require(
            canReleaseAmount >= releasedAssetAmount[index],
            "can't release this lock, can release amount less than released amount"
        );

        uint256 totalRealeaseAmountX18 = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            totalRealeaseAmountX18 += amountX18List[i];
        }
        uint256 totalRealeaseAmount = X18Helper.fromX18ToNormalDecimal(
            totalRealeaseAmountX18,
            config.asset
        );

        require(
            totalRealeaseAmount <=
                (canReleaseAmount - releasedAssetAmount[index]),
            "can't release, can release amount less than want release amount"
        );

        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 amount = X18Helper.fromX18ToNormalDecimal(
                amountX18List[i],
                config.asset
            );

            if (needAirDrop) {
                IVault(vaultAddress).withdraw(
                    recipients[i],
                    config.asset,
                    amount
                );
            } else {
                userCanClaimAssetAmount[index][recipients[i]] += amount;
            }
        }

        releasedAssetAmount[index] += totalRealeaseAmount;
        totalReleasedAsset[config.asset] += totalRealeaseAmount;
    }

    function _processUnLockAsset(
        bool needAirDrop,
        address token,
        address[] memory recipients,
        uint256[] memory amountX18List
    ) private {
        require(
            recipients.length == amountX18List.length,
            "list length not equal"
        );
        uint256 canUseAmount = IERC20(token).balanceOf(vaultAddress);
        canUseAmount -= totalLockedAsset[token];
        canUseAmount -= usedUnlockAsset[token];

        uint256 useAmountX18 = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            useAmountX18 += amountX18List[i];
        }
        uint256 useAmount = X18Helper.fromX18ToNormalDecimal(
            useAmountX18,
            token
        );

        require(useAmount <= canUseAmount, "insufficient unlocked asset");
        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 amount = X18Helper.fromX18ToNormalDecimal(
                amountX18List[i],
                token
            );

            if (needAirDrop) {
                IVault(vaultAddress).withdraw(recipients[i], token, amount);
            } else {
                userCanClaimUnlockAssetAmount[token][recipients[i]] += amount;
            }
        }
    }

    function _transferUnLockAssetToOtherModule(
        address token,
        uint256 amountX18,
        uint8 moduleIndex
    ) private {
        uint256 canUseAmount = IERC20(token).balanceOf(vaultAddress);
        canUseAmount -= totalLockedAsset[token];
        canUseAmount -= usedUnlockAsset[token];

        uint256 amount = X18Helper.fromX18ToNormalDecimal(amountX18, token);

        require(amount <= canUseAmount, "insufficient unlocked asset");
        require(
            otherModuleAddress[moduleIndex] != address(0x0),
            "module not init"
        );

        IVault(vaultAddress).withdraw(
            otherModuleAddress[moduleIndex],
            token,
            amount
        );
    }

    function _transferReleasedAssetToOtherModule(
        uint64 index,
        uint256 amountX18,
        uint8 moduleIndex
    ) private {
        OnChainLockConfig memory config = lockConfigMap[index];
        address token = config.asset;

        uint256 canReleaseAmount = getCanReleaseAmount(config);
        require(
            canReleaseAmount >= releasedAssetAmount[index],
            "can't release this lock, can release amount less than released amount"
        );

        uint256 amount = X18Helper.fromX18ToNormalDecimal(amountX18, token);
        require(
            amount <= (canReleaseAmount - releasedAssetAmount[index]),
            "can't release, can release amount less than want release amount"
        );
        require(
            otherModuleAddress[moduleIndex] != address(0x0),
            "module not init"
        );

        IVault(vaultAddress).withdraw(
            otherModuleAddress[moduleIndex],
            token,
            amount
        );
    }

    function getCanReleaseAmount(
        OnChainLockConfig memory config
    ) private view returns (uint256) {
        if (config.lockType == LockType.linearRelease) {
            return getLinerCanReleaseAmount(config);
        } else if (config.lockType == LockType.staticRelease) {
            return getStaticCanReleaseAmount(config);
        }

        return 0;
    }

    function removeConfigDetailAmountX18(
        address asset,
        LockType lockType,
        bytes memory detail
    ) private view returns (bytes memory) {
        if (lockType == LockType.linearRelease) {
            return removeLinerConfigDetailAmountX18(asset, detail);
        } else if (lockType == LockType.staticRelease) {
            return removeStaticConfigDetailAmountX18(asset, detail);
        }

        revert LockTypeNotSupport();
    }

    function removeLinerConfigDetailAmountX18(
        address asset,
        bytes memory data
    ) private view returns (bytes memory) {
        TreasuryLinearReleaseConfig memory detail = abi.decode(
            data,
            (TreasuryLinearReleaseConfig)
        );

        detail.amountPreRound = X18Helper.fromX18ToNormalDecimal(
            detail.amountPreRound,
            asset
        );

        return abi.encode(detail);
    }

    function removeStaticConfigDetailAmountX18(
        address asset,
        bytes memory data
    ) private view returns (bytes memory) {
        TreasuryStaticReleaseConfig memory detail = abi.decode(
            data,
            (TreasuryStaticReleaseConfig)
        );

        for (uint256 i = 0; i < detail.releaseAmount.length; i++) {
            detail.releaseAmount[i] = X18Helper.fromX18ToNormalDecimal(
                detail.releaseAmount[i],
                asset
            );
        }

        return abi.encode(detail);
    }

    function getLinerCanReleaseAmount(
        OnChainLockConfig memory config
    ) private view returns (uint256) {
        TreasuryLinearReleaseConfig memory detail = abi.decode(
            config.configDetail,
            (TreasuryLinearReleaseConfig)
        );

        if (block.number < detail.startReleaseBlockHeight) {
            return 0;
        }

        uint256 round = (block.number - detail.startReleaseBlockHeight) /
            detail.duration;
        uint256 maxRound = config.lockAssetAmount / detail.amountPreRound;
        if (round > maxRound) {
            round = maxRound;
        }
        return (round * detail.amountPreRound);
    }

    function getStaticCanReleaseAmount(
        OnChainLockConfig memory config
    ) private view returns (uint256) {
        TreasuryStaticReleaseConfig memory detail = abi.decode(
            config.configDetail,
            (TreasuryStaticReleaseConfig)
        );

        uint256 totalReleased = 0;
        for (uint256 i = 0; i < detail.releaseBlockHeight.length; i++) {
            if (block.number < detail.releaseBlockHeight[i]) {
                return totalReleased;
            }

            totalReleased += detail.releaseAmount[i];
        }

        return totalReleased;
    }

    // ==================== utils ====================

    // ==================== manager area ====================

    function setVaultAddress(address _vaultAddress) external onlyOwner {
        if (vaultAddress == address(0x0)) {
            vaultAddress = _vaultAddress;
        }
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

    modifier onlyExchange() {
        if (msg.sender != otherModuleAddress[MODULE_INDEX_EXCHANGE]) {
            revert OnlyExchangeCanCall();
        }
        _;
    }

    modifier onlyUserManager() {
        if (msg.sender != otherModuleAddress[MODULE_INDEX_USER]) {
            revert OnlyUserManagerCanCall();
        }
        _;
    }

    modifier onlyMulSign(bytes32 data, bytes[] calldata signList) {
        require(signList.length == signerList.length);

        uint8 cnt = 0;
        for (uint256 i = 0; i < signList.length; i++) {
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
}
