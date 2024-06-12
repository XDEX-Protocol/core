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

import "./interfaces/IOnChainStruct.sol";
import "./interfaces/IERC20Decimals.sol";
import "./interfaces/IUserManager.sol";
import "./interfaces/ILPManager.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IVault.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";
import "./utils/EmergencyStop.sol";
import "./Pool.sol";
import "./libraries/X18Helper.sol";

contract LPManager is
    ILPManager,
    IOnChainStruct,
    EmergencyStop,
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

    mapping(address => mapping(uint64 => uint256)) public lastBuyTimestamp; // Map<address, Map<poolIndex, last buy pool share timestamp>>

    mapping(uint64 => address) public poolAddress; // Map<poolIndex, poolAddress>
    mapping(uint64 => OnChainPoolConfig) public poolConfig; // Map<poolIndex, poolConfig>
    mapping(uint64 => uint256) public poolSharePrice; // Map<poolIndex, vaule pre share>
    mapping(uint64 => uint256) public reciprocalPoolSharePrices; // Map<poolIndex, share pre asset>

    mapping(uint64 => bool) public processedRedeem; // Map<requestId, processed>
    mapping(uint64 => uint256) public poolHoldAvailableShareAmount; // Map<poolIndex, availableShareAmount>  shares that can use for amm
    mapping(uint64 => uint8) public sharePriceDecimal; // Map<poolIndex, share price decimal>

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

    function batchProcess(
        bytes[] calldata waitProcessData
    ) external onlyExchange {}

    function batchProcessAction2(
        bytes[] calldata waitProcessData
    ) external onlyExchange {
        for (uint256 index = 0; index < waitProcessData.length; index++) {
            processDetail(waitProcessData[index]);
        }
    }

    function buyLPShare(
        uint64 poolIndex,
        address from,
        address asset,
        uint256 amount
    ) external {
        if (msg.sender != from) {
            revert InvalidBuyerAddress(from);
        }

        poolMustExist(poolIndex);

        address assetToken = poolConfig[poolIndex].availableToken;
        if (assetToken != asset) {
            revert TokenNotSupport(asset);
        }

        uint256 maxShare = previewPoolDeposit(poolIndex, from, amount);
        if (maxShare <= 0) {
            revert("amount is too small to convert to share");
        }

        uint256 assetAmount = maxShare * poolSharePrice[poolIndex];
        assetAmount = X18Helper.addAssetDecimal(assetAmount, assetToken);
        assetAmount = X18Helper.removeAssetDecimal(
            assetAmount,
            sharePriceDecimal[poolIndex]
        );
        assetAmount = X18Helper.removeAssetDecimal(
            assetAmount,
            poolAddress[poolIndex]
        );

        if (assetAmount == 0) {
            revert AmountTooSmall();
        }

        IERC20(asset).safeTransferFrom(from, vaultAddress, assetAmount);

        IPool(poolAddress[poolIndex]).buyShare(from, maxShare);
        poolHoldAvailableShareAmount[poolIndex] += maxShare;

        lastBuyTimestamp[from][poolIndex] = block.timestamp;

        // convert to x18
        uint256 shareX18 = X18Helper.toX18(maxShare, poolAddress[poolIndex]);
        uint256 assetAmountX18 = X18Helper.toX18(assetAmount, asset);

        emit PoolShareAdd(poolIndex, from, shareX18, assetAmountX18);
    }

    function redeemRequest(
        uint64 poolIndex,
        address from,
        uint256 share
    ) external withdrawIsEnable {
        poolMustExist(poolIndex);
        require(
            block.timestamp - lastBuyTimestamp[from][poolIndex] < 1 days,
            "shares cannot be redeemed within 1 day of purchase"
        );

        IERC20(poolAddress[poolIndex]).safeTransferFrom(
            from,
            poolAddress[poolIndex],
            share
        );

        uint256 shareX18 = X18Helper.toX18(share, poolAddress[poolIndex]);

        emit redeemRequestReceived(poolIndex, from, shareX18);
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

    function sharePrice(uint64 poolIndex) external view returns (uint256) {
        return poolSharePrice[poolIndex];
    }

    function reciprocalSharePrice(
        uint64 poolIndex
    ) external view returns (uint256) {
        return reciprocalPoolSharePrices[poolIndex];
    }

    function availablePoolIndex(uint64 poolIndex) external view returns (bool) {
        return poolAddress[poolIndex] != address(0x0);
    }

    function getPoolAddress(uint64 poolIndex) external view returns (address) {
        return poolAddress[poolIndex];
    }

    function getVaultAddress() external view returns (address) {
        return vaultAddress;
    }

    function getPoolShareDecimal(
        uint64 poolIndex
    ) external view returns (uint8) {
        return IERC20Decimals(poolAddress[poolIndex]).decimals();
    }

    function getPoolSharePriceDecimal(
        uint64 poolIndex
    ) external view returns (uint8) {
        return sharePriceDecimal[poolIndex];
    }

    function getPoolConfigInfo(
        uint64 poolIndex
    ) external view returns (address, uint256, uint256, uint256) {
        OnChainPoolConfig memory info = poolConfig[poolIndex];

        return (
            poolAddress[info.poolIndex],
            info.poolMaxHoldAsset,
            info.userMinDepositAsset,
            info.userMaxDepositAsset
        );
    }

    function getAssetToken(uint64 poolIndex) external view returns (address) {
        OnChainPoolConfig memory info = poolConfig[poolIndex];
        return info.availableToken;
    }

    function processDetail(bytes calldata data) private {
        Action2 action = Action2(uint8(data[0]));
        if (action == Action2.addNewPool) {
            addNewPool(data[1:]);
        } else if (action == Action2.updatePoolConfig) {
            updatePoolConfig(data[1:]);
        } else if (action == Action2.updatePoolSharePrice) {
            updatePoolSharePrice(data[1:]);
        } else if (action == Action2.redeemPoolShare) {
            redeemPoolShare(data[1:]);
        }
    }

    function addNewPool(bytes calldata data) private {
        AddNewPoolInfo memory info = abi.decode(data, (AddNewPoolInfo));

        poolCannotExist(info.poolIndex);

        bytes32 salt = keccak256(abi.encodePacked(info.poolIndex));

        bytes memory bytecode = abi.encodePacked(
            type(Pool).creationCode,
            abi.encode(info._shareName, info._shareSymbol, info.shareDecimal)
        );

        address _poolAddress = Create2.deploy(0, salt, bytecode);

        uint256 sharePriceInReal = X18Helper.fromX18ToNormalDecimal(
            info.sharePriceX18,
            info.sharePriceDecimal
        );

        if (sharePriceInReal == 0) {
            revert SharePriceCannotLessThanZereo();
        }

        if (info.reciprocalSharePriceX18 == 0) {
            revert ReciprocalSharePriceCannotLessThanZereo();
        }

        poolAddress[info.poolIndex] = _poolAddress;
        poolSharePrice[info.poolIndex] = sharePriceInReal;
        reciprocalPoolSharePrices[info.poolIndex] = info
            .reciprocalSharePriceX18;

        poolConfig[info.poolIndex] = OnChainPoolConfig(
            info.poolIndex,
            info.availableToken,
            X18Helper.fromX18ToNormalDecimal(
                info.maxHoldAssetX18,
                info.availableToken
            ),
            X18Helper.fromX18ToNormalDecimal(
                info.minDepositAssetAmountX18,
                info.availableToken
            ),
            X18Helper.fromX18ToNormalDecimal(
                info.maxDepositAssetX18,
                info.availableToken
            ),
            info.shareDecimal,
            info.sharePriceDecimal
        );
        sharePriceDecimal[info.poolIndex] = info.sharePriceDecimal;

        emit NewPoolAdded(
            info.poolIndex,
            _poolAddress,
            info.availableToken,
            info.sharePriceX18
        );
    }

    function updatePoolConfig(bytes calldata data) private {
        UpdatePoolConfigInfo memory info = abi.decode(
            data,
            (UpdatePoolConfigInfo)
        );
        poolMustExist(info.poolIndex);

        address assetToken = poolConfig[info.poolIndex].availableToken;

        poolConfig[info.poolIndex].poolMaxHoldAsset = X18Helper
            .fromX18ToNormalDecimal(info.maxHoldAssetX18, assetToken);

        poolConfig[info.poolIndex].userMinDepositAsset = X18Helper
            .fromX18ToNormalDecimal(info.minDepositAssetAmountX18, assetToken);

        poolConfig[info.poolIndex].userMaxDepositAsset = X18Helper
            .fromX18ToNormalDecimal(info.maxDepositAssetX18, assetToken);
    }

    function updatePoolSharePrice(bytes calldata data) private {
        PoolSharePriceInfo memory info = abi.decode(data, (PoolSharePriceInfo));

        if (info.poolIndex.length != info.sharePriceX18.length) {
            revert InvalidDataLength();
        }

        for (uint256 i = 0; i < info.poolIndex.length; i++) {
            uint64 poolIndex = info.poolIndex[i];
            uint256 sharePriceX18 = info.sharePriceX18[i];
            uint256 reciprocalSharePriceX18 = info.reciprocalSharePriceX18[i];

            poolMustExist(poolIndex);

            uint8 _sharePriceDecimal = sharePriceDecimal[poolIndex];
            uint256 sharePriceInReal = X18Helper.fromX18ToNormalDecimal(
                sharePriceX18,
                _sharePriceDecimal
            );

            if (sharePriceInReal == 0) {
                revert SharePriceCannotLessThanZereo();
            }

            if (reciprocalSharePriceX18 == 0) {
                revert ReciprocalSharePriceCannotLessThanZereo();
            }

            poolSharePrice[poolIndex] = sharePriceInReal;
            reciprocalPoolSharePrices[poolIndex] = reciprocalSharePriceX18;

            emit PoolShareValueUpdated(poolIndex, sharePriceX18);
        }
    }

    function redeemPoolShare(bytes calldata data) private withdrawIsEnable {
        RedeemPoolShareList memory resultList = abi.decode(
            data,
            (RedeemPoolShareList)
        );

        for (uint256 i = 0; i < resultList.list.length; i++) {
            RedeemPoolShareInfo memory info = resultList.list[i];

            poolMustExist(info.poolIndex);
            if (processedRedeem[info.requestId]) {
                revert RedeemRequestAlreadyProcessed(info.requestId);
            }
            processedRedeem[info.requestId] = true;

            address assetToken = poolConfig[info.poolIndex].availableToken;
            uint8 _sharePriceDecimal = sharePriceDecimal[info.poolIndex];

            uint256 shareInReal = X18Helper.fromX18ToNormalDecimal(
                info.shareX18,
                poolAddress[info.poolIndex]
            );

            uint256 sharePriceInReal = X18Helper.fromX18ToNormalDecimal(
                info.sharePriceX18,
                _sharePriceDecimal
            );

            if (sharePriceInReal == 0) {
                revert SharePriceCannotLessThanZereo();
            }

            if (info.reciprocalSharePriceX18 == 0) {
                revert ReciprocalSharePriceCannotLessThanZereo();
            }

            uint256 reciprocalPoolSharePriceInReal = X18Helper
                .fromX18ToNormalDecimal(
                    info.reciprocalSharePriceX18,
                    poolAddress[info.poolIndex]
                );

            if (sharePriceInReal == 0 || reciprocalPoolSharePriceInReal == 0) {
                revert InvalidSharePrice();
            }

            if (info.approved) {
                IPool(poolAddress[info.poolIndex]).burnRedeemShare(shareInReal);

                uint256 amountInReal = shareInReal * sharePriceInReal;
                amountInReal = X18Helper.addAssetDecimal(
                    amountInReal,
                    assetToken
                );
                amountInReal = X18Helper.removeAssetDecimal(
                    amountInReal,
                    sharePriceDecimal[info.poolIndex]
                );
                amountInReal = X18Helper.removeAssetDecimal(
                    amountInReal,
                    poolAddress[info.poolIndex]
                );

                IVault(vaultAddress).withdraw(
                    info.toAddress,
                    assetToken,
                    amountInReal
                );
            } else {
                IPool(poolAddress[info.poolIndex]).rejectRedeemShare(
                    info.toAddress,
                    shareInReal
                );
            }

            poolSharePrice[info.poolIndex] = sharePriceInReal;
            reciprocalPoolSharePrices[info.poolIndex] = info
                .reciprocalSharePriceX18;

            emit PoolShareValueUpdated(info.poolIndex, info.sharePriceX18);

            emit redeemRequestProcessed(
                info.requestId,
                true,
                !info.approved,
                info.shareX18,
                poolSharePrice[info.poolIndex]
            );
        }
    }

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

    // ==================== utils ====================
    function poolMustExist(uint64 poolIndex) private view {
        if (poolAddress[poolIndex] == address(0x0)) {
            revert PoolNotExist(poolIndex);
        }
    }

    function poolCannotExist(uint64 poolIndex) private view {
        if (poolAddress[poolIndex] != address(0x0)) {
            revert PoolExist(poolIndex);
        }
    }

    function previewPoolDeposit(
        uint64 poolIndex,
        address user,
        uint256 depositAssetamount
    ) private view returns (uint256) {
        OnChainPoolConfig memory config = poolConfig[poolIndex];
        address assetToken = config.availableToken;
        uint256 userMinDepositAssetOnce = config.userMinDepositAsset;
        uint256 userMaxDepositAsset = config.userMaxDepositAsset;
        address _poolAddress = poolAddress[poolIndex];

        if (depositAssetamount < userMinDepositAssetOnce) {
            revert AmountTooSmall();
        }

        uint256 maxCanUseAsset = getPoolMaxAvailableAsset(
            poolIndex,
            _poolAddress
        );

        if (maxCanUseAsset < depositAssetamount) {
            revert AmountLargeThanPoolMaxCanDeposit();
        }

        uint256 userCurrentAsset = convertToPoolAssetAmount(
            poolIndex,
            _poolAddress,
            IERC20(_poolAddress).balanceOf(user)
        );

        maxCanUseAsset = maxCanUseAsset > userMaxDepositAsset - userCurrentAsset
            ? userMaxDepositAsset - userCurrentAsset
            : maxCanUseAsset;

        uint256 canUseAsset = depositAssetamount > maxCanUseAsset
            ? 0
            : depositAssetamount;
        if (canUseAsset == 0) {
            revert AmountLargeThanUserMaxCanDeposit();
        }

        uint256 maxConvertShare = convertToPoolShares(
            poolIndex,
            assetToken,
            canUseAsset
        );

        return maxConvertShare;
    }

    function getPoolMaxAvailableAsset(
        uint64 poolIndex,
        address _poolAddress
    ) private view returns (uint256) {
        OnChainPoolConfig memory config = poolConfig[poolIndex];
        uint256 poolMaxHoldAsset = config.poolMaxHoldAsset;

        uint256 poolCurrentSupplyShare = IERC20(_poolAddress).totalSupply();
        uint256 poolCurrentHoldAsset = convertToPoolAssetAmount(
            poolIndex,
            _poolAddress,
            poolCurrentSupplyShare
        );

        uint256 maxCanUseAsset = poolMaxHoldAsset > poolCurrentHoldAsset
            ? poolMaxHoldAsset - poolCurrentHoldAsset
            : 0;
        if (maxCanUseAsset <= 0) {
            revert PoolIsFull();
        }

        return maxCanUseAsset;
    }

    function convertToPoolAssetAmount(
        uint64 poolIndex,
        address _poolAddress,
        uint256 shareAmount
    ) private view returns (uint256) {
        return
            X18Helper.removeAssetDecimal(
                shareAmount * poolSharePrice[poolIndex],
                _poolAddress
            );
    }

    function convertToPoolShares(
        uint64 poolIndex,
        address assetToken,
        uint256 assetamount
    ) private view returns (uint256) {
        uint256 shareAmountWithAssetDecimalX18 = assetamount *
            reciprocalPoolSharePrices[poolIndex];

        uint256 shareAmountWithAssetDecimal = X18Helper.fromX18ToNormalDecimal(
            shareAmountWithAssetDecimalX18,
            poolAddress[poolIndex]
        );

        return
            X18Helper.removeAssetDecimal(
                shareAmountWithAssetDecimal,
                assetToken
            );
    }
}
