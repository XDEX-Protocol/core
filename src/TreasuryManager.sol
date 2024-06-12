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
import "./utils/RefundDeposit.sol";
import "./libraries/X18Helper.sol";

contract TreasuryManager is
    ITreasuryManager,
    EmergencyStop,
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

    mapping(TreasuryAssetType => mapping(address => uint256)) public totalAsset; // Map<AssetType, Map<asset, amount>>
    mapping(TreasuryAssetType => mapping(uint64 => OnChainLockConfig))
        public lockConfigMap; // Map<AssetType, Map<configIndex, config>> lock config
    mapping(TreasuryAssetType => mapping(address => uint256))
        public totalLockedAsset; // Map<AssetType, Map<asset, amount>>
    mapping(TreasuryAssetType => mapping(address => uint256))
        public totalReleasedAsset; // Map<AssetType, Map<asset, amount>>
    mapping(TreasuryAssetType => mapping(address => uint256))
        public usedUnlockAsset; // Map<AssetType, Map<asset, amount>>
    mapping(TreasuryAssetType => mapping(uint64 => uint256))
        public canReleaseAssetAmount; // Map<AssetType, Map<configIndex, amount>>
    mapping(TreasuryAssetType => mapping(uint64 => uint256))
        public releasedAssetAmount; // Map<AssetType, Map<configIndex, amount>>
    mapping(TreasuryAssetType => mapping(uint64 => mapping(address => uint256)))
        public userCanClaimAssetAmount; // Map<AssetType, Map<configIndex, Map<walletAddress, amount>>>
    mapping(TreasuryAssetType => mapping(uint64 => mapping(address => uint256)))
        public userClaimedAssetAmount; // Map<AssetType, Map<configIndex, Map<walletAddress, amount>>>
    mapping(TreasuryAssetType => mapping(address => mapping(address => uint256)))
        public userCanClaimUnlockAssetAmount; // Map<AssetType, Map<coinAddress, Map<walletAddress, amount>>>

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
        require(initialOwner != address(0x0), "invalid initial owner");
        require(signerList_.length > 0, "invalid signer list");
        require(threshold_ <= signerList_.length, "invalid threshold");
        require(exchangeAddress != address(0x0), "invalid exchange address");

        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();
        SetupEmergencyStop(exchangeAddress, signerList_, threshold_);

        signerList = signerList_;
        threshold = threshold_;
        otherModuleAddress[MODULE_INDEX_EXCHANGE] = exchangeAddress;
    }

    receive() external payable {}

    function deposit(
        TreasuryAssetType assetType,
        address asset,
        uint256 amount
    ) external {
        IERC20(asset).safeTransferFrom(msg.sender, vaultAddress, amount);

        totalAsset[assetType][asset] += amount;
    }

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
                addLockConfig(data);
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

    function claimUnLockAsset(
        TreasuryAssetType assetType,
        address asset
    ) external withdrawIsEnable returns (uint256 amount) {
        if (userCanClaimUnlockAssetAmount[assetType][asset][msg.sender] == 0) {
            return amount;
        }

        amount = userCanClaimUnlockAssetAmount[assetType][asset][msg.sender];
        userCanClaimUnlockAssetAmount[assetType][asset][msg.sender] = 0;

        IVault(vaultAddress).withdraw(msg.sender, asset, amount);

        emit UnlockAssetClaimed(assetType, asset, msg.sender, amount);
    }

    function claimReleasedAsset(
        TreasuryAssetType assetType,
        uint64 index
    ) external withdrawIsEnable returns (address asset, uint256 amount) {
        if (lockConfigMap[assetType][index].index != index) {
            revert InvalidLockConfig();
        }

        OnChainLockConfig memory config = lockConfigMap[assetType][index];
        asset = config.asset;
        amount = 0;

        if (userCanClaimAssetAmount[assetType][index][msg.sender] == 0) {
            return (asset, amount);
        }
        uint256 canClaimAssetAmount = userCanClaimAssetAmount[assetType][index][
            msg.sender
        ];

        if (
            userClaimedAssetAmount[assetType][index][msg.sender] >=
            canClaimAssetAmount
        ) {
            return (asset, amount);
        }

        amount =
            canClaimAssetAmount -
            userClaimedAssetAmount[assetType][index][msg.sender];

        userClaimedAssetAmount[assetType][index][msg.sender] += amount;
        IVault(vaultAddress).withdraw(msg.sender, asset, amount);
    }

    function refreshCanReleaseAssetAmount(
        TreasuryAssetType assetType,
        uint64[] calldata configIndexList
    ) external {
        _refreshCanReleaseAssetAmount(assetType, configIndexList);
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
        TreasuryAssetType assetType,
        uint64 index,
        address walletAddress
    ) external view returns (uint256 amount, address asset, uint8 decimal) {
        OnChainLockConfig memory info = lockConfigMap[assetType][index];
        amount =
            userCanClaimAssetAmount[assetType][index][walletAddress] -
            userClaimedAssetAmount[assetType][index][walletAddress];
        return (amount, info.asset, IERC20Decimals(info.asset).decimals());
    }

    function getAvailableUnlockAmount(
        TreasuryAssetType assetType,
        address asset,
        address walletAddress
    ) external view returns (uint256 amount, address asset_, uint8 decimal) {
        return (
            userCanClaimUnlockAssetAmount[assetType][asset][walletAddress],
            asset,
            IERC20Decimals(asset).decimals()
        );
    }

    function _refreshCanReleaseAssetAmount(
        TreasuryAssetType assetType,
        uint64[] memory configIndexList
    ) private {
        for (uint256 i = 0; i < configIndexList.length; i++) {
            uint64 configIndex = configIndexList[i];

            OnChainLockConfig memory config = lockConfigMap[assetType][
                configIndex
            ];

            if (config.index != configIndex) {
                revert InvalidLockConfig();
            }

            uint256 beforeCanRelease = canReleaseAssetAmount[assetType][
                configIndex
            ];
            canReleaseAssetAmount[assetType][configIndex] = getCanReleaseAmount(
                config
            );

            // already release asset can't lock by same config again
            if (
                beforeCanRelease > canReleaseAssetAmount[assetType][configIndex]
            ) {
                totalLockedAsset[assetType][
                    config.asset
                ] -= (canReleaseAssetAmount[assetType][configIndex] -
                    beforeCanRelease);
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
            info.assetType,
            info.index,
            info.lockAsset,
            info.canUpdateConfig,
            info.lockType,
            info.lockAssetAmountX18,
            info.configDetail
        );
    }

    function _addLockConfig(
        TreasuryAssetType assetType,
        uint64 index,
        address lockAsset,
        bool canUpdateConfig,
        LockType lockType,
        uint256 lockAssetAmountX18,
        bytes memory configDetail
    ) private {
        if (vaultAddress == address(0x0)) {
            revert VaultNotInit();
        }

        uint256 lockAssetAmount = X18Helper.fromX18ToNormalDecimal(
            lockAssetAmountX18,
            lockAsset
        );

        if (lockAssetAmount == 0) {
            revert InvalidLockAmount();
        }
        if (lockConfigMap[assetType][index].lockAssetAmount != 0) {
            revert DuplicateLockConfigIndex(index);
        }

        lockConfigMap[assetType][index] = OnChainLockConfig(
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
            totalAsset[assetType][lockAsset] <
            lockAssetAmount +
                totalLockedAsset[assetType][lockAsset] -
                totalReleasedAsset[assetType][lockAsset] -
                usedUnlockAsset[assetType][lockAsset]
        ) {
            revert InsufficientFreeAssetAmount(
                lockAsset,
                totalAsset[assetType][lockAsset],
                lockAssetAmount,
                totalLockedAsset[assetType][lockAsset],
                totalReleasedAsset[assetType][lockAsset]
            );
        }

        uint64[] memory targetConfigList = new uint64[](1);
        targetConfigList[0] = index;
        _refreshCanReleaseAssetAmount(assetType, targetConfigList);

        totalLockedAsset[assetType][lockAsset] += lockAssetAmount;

        emit NewLockConfigAdded(index, lockAsset, lockAssetAmount);
    }

    function processReleasedAsset(bytes calldata data) private {
        ProcessReleasedAssetInfo memory info = abi.decode(
            data[1:],
            (ProcessReleasedAssetInfo)
        );
        _processReleasedAsset(
            info.assetType,
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
            info.assetType,
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
            info.assetType,
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
            info.assetType,
            info.index,
            info.amountX18,
            info.moduleIndex
        );
    }

    function _processReleasedAsset(
        TreasuryAssetType assetType,
        bool needAirDrop,
        uint64 index,
        address[] memory recipients,
        uint256[] memory amountX18List
    ) private withdrawIsEnable {
        if (lockConfigMap[assetType][index].index != index) {
            revert InvalidLockConfig();
        }

        if (recipients.length != amountX18List.length) {
            revert InvalidDataLength();
        }
        OnChainLockConfig memory config = lockConfigMap[assetType][index];

        uint256 canReleaseAmount = getCanReleaseAmount(config);
        if (canReleaseAmount < releasedAssetAmount[assetType][index]) {
            revert InsufficientReleasedAsset(
                canReleaseAmount,
                releasedAssetAmount[assetType][index]
            );
        }

        uint256 totalRealeaseAmountX18 = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            totalRealeaseAmountX18 += amountX18List[i];
        }
        uint256 totalRealeaseAmount = X18Helper.fromX18ToNormalDecimal(
            totalRealeaseAmountX18,
            config.asset
        );

        if (
            totalRealeaseAmount >
            (canReleaseAmount - releasedAssetAmount[assetType][index])
        ) {
            revert InsufficientReleasedAsset(
                canReleaseAmount,
                releasedAssetAmount[assetType][index]
            );
        }

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
                userCanClaimAssetAmount[assetType][index][
                    recipients[i]
                ] += amount;
            }
        }

        releasedAssetAmount[assetType][index] += totalRealeaseAmount;
        totalReleasedAsset[assetType][config.asset] += totalRealeaseAmount;
    }

    function _processUnLockAsset(
        TreasuryAssetType assetType,
        bool needAirDrop,
        address token,
        address[] memory recipients,
        uint256[] memory amountX18List
    ) private withdrawIsEnable {
        if (recipients.length != amountX18List.length) {
            revert InvalidDataLength();
        }

        uint256 canUseAmount = totalAsset[assetType][token];
        canUseAmount -= totalLockedAsset[assetType][token];
        canUseAmount -= usedUnlockAsset[assetType][token];

        uint256 useAmountX18 = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            useAmountX18 += amountX18List[i];
        }
        uint256 useAmount = X18Helper.fromX18ToNormalDecimal(
            useAmountX18,
            token
        );

        if (useAmount >= canUseAmount) {
            revert InsufficientUnlockAsset(token, useAmount, canUseAmount);
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            uint256 amount = X18Helper.fromX18ToNormalDecimal(
                amountX18List[i],
                token
            );

            if (needAirDrop) {
                IVault(vaultAddress).withdraw(recipients[i], token, amount);
                usedUnlockAsset[assetType][token] += amount;
            } else {
                userCanClaimUnlockAssetAmount[assetType][token][
                    recipients[i]
                ] += amount;
                usedUnlockAsset[assetType][token] += amount;

                emit CanClaimUnlockAssetAdded(
                    assetType,
                    token,
                    recipients[i],
                    amount,
                    needAirDrop
                );
            }
        }
    }

    function _transferUnLockAssetToOtherModule(
        TreasuryAssetType assetType,
        address token,
        uint256 amountX18,
        uint8 moduleIndex
    ) private withdrawIsEnable {
        uint256 canUseAmount = totalAsset[assetType][token];
        canUseAmount -= totalLockedAsset[assetType][token];
        canUseAmount -= usedUnlockAsset[assetType][token];

        uint256 amount = X18Helper.fromX18ToNormalDecimal(amountX18, token);

        if (amount <= canUseAmount) {
            revert InsufficientUnlockAsset(token, amount, canUseAmount);
        }

        if (otherModuleAddress[moduleIndex] == address(0x0)) {
            revert ModuleNotInit(moduleIndex);
        }

        IVault(vaultAddress).withdraw(
            otherModuleAddress[moduleIndex],
            token,
            amount
        );
    }

    function _transferReleasedAssetToOtherModule(
        TreasuryAssetType assetType,
        uint64 index,
        uint256 amountX18,
        uint8 moduleIndex
    ) private withdrawIsEnable {
        OnChainLockConfig memory config = lockConfigMap[assetType][index];
        address token = config.asset;

        uint256 canReleaseAmount = getCanReleaseAmount(config);

        if (canReleaseAmount < releasedAssetAmount[assetType][index]) {
            revert InsufficientReleasedAsset(
                canReleaseAmount,
                releasedAssetAmount[assetType][index]
            );
        }

        uint256 amount = X18Helper.fromX18ToNormalDecimal(amountX18, token);

        if (
            amount > (canReleaseAmount - releasedAssetAmount[assetType][index])
        ) {
            revert InsufficientReleasedAsset(
                canReleaseAmount,
                releasedAssetAmount[assetType][index]
            );
        }

        if (otherModuleAddress[moduleIndex] == address(0x0)) {
            revert ModuleNotInit(moduleIndex);
        }

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

    modifier onlyUserManager() {
        if (msg.sender != otherModuleAddress[MODULE_INDEX_USER]) {
            revert OnlyUserManagerCanCall();
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
}
