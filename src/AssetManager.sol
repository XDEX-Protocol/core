// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./interfaces/IERC20Decimals.sol";

contract AssetManager is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    enum AssetType {
        FoundingTeam,
        EarlyInvestors,
        InitialStage,
        ContinuousMotivation,
        Ecosystem,
        Community,
        Advisor
    }

    address[] public signerList;
    uint public threshold;
    address public manager;

    uint startTime;
    address asset;
    address treasuryVaultAddress;
    mapping(AssetType => uint256) public canReleaseAsset;
    mapping(AssetType => uint256) public releasedAsset;
    mapping(AssetType => uint) public lockTimeInDays;
    uint[] dayCntOfMonth;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        address manager_,
        address[] memory signerList_,
        uint8 threshold_,
        address asset_,
        address treasuryVaultAddress_
    ) public initializer {
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        manager = manager_;
        signerList = signerList_;
        threshold = threshold_;

        asset = asset_;
        treasuryVaultAddress = treasuryVaultAddress_;

        canReleaseAsset[AssetType.FoundingTeam] = 2 * 10 ** 8;
        canReleaseAsset[AssetType.EarlyInvestors] = 2 * 10 ** 8;
        canReleaseAsset[AssetType.InitialStage] = 2 * 10 ** 8;
        canReleaseAsset[AssetType.ContinuousMotivation] = 3 * 10 ** 8;
        canReleaseAsset[AssetType.Ecosystem] = 5 * 10 ** 7;
        canReleaseAsset[AssetType.Community] = 4 * 10 ** 7;
        canReleaseAsset[AssetType.Advisor] = 1 * 10 ** 7;
    }

    function start(
        uint foundingTeamLockTimeInDays,
        uint EarlyInvestorLockTimeInDays,
        uint ContinuousMotivationLockTimeInDays,
        uint CommunityLockTimeInDays,
        uint[] calldata dayCntOfMonth_
    ) external returns (bool success) {
        require(dayCntOfMonth_.length == 24, "must give 24 month day count");

        if (IERC20(asset).balanceOf(address(this)) != 10 ** 9) {
            return false;
        }

        startTime = block.timestamp;
        dayCntOfMonth = dayCntOfMonth_;

        lockTimeInDays[AssetType.FoundingTeam] = foundingTeamLockTimeInDays;
        lockTimeInDays[AssetType.EarlyInvestors] = EarlyInvestorLockTimeInDays;
        lockTimeInDays[
            AssetType.ContinuousMotivation
        ] = ContinuousMotivationLockTimeInDays;
        lockTimeInDays[AssetType.Community] = CommunityLockTimeInDays;

        return true;
    }

    function receiveLinearReleaseAsset(
        AssetType assetType,
        address targetAddress,
        bytes[] calldata signList
    )
        external
        afterLinearCanReleaseTime(assetType)
        returns (bool success, uint256 amount)
    {
        require(passMulSign(targetAddress, signList), "mul sign check failed");

        uint canReleaseMouth = getLinearCanReleaseMonth(assetType);
        uint canReleaseAmount = (canReleaseAsset[assetType] /
            dayCntOfMonth.length) * canReleaseMouth;

        if (canReleaseMouth == dayCntOfMonth.length) {
            // release all asset
            canReleaseAmount = canReleaseAsset[assetType];
        }

        uint256 realReleaseAmount = canReleaseAmount - releasedAsset[assetType];

        releasedAsset[assetType] += realReleaseAmount;

        uint8 decimal = IERC20Decimals(asset).decimals();
        IERC20(asset).safeTransfer(
            treasuryVaultAddress,
            realReleaseAmount * 10 ** decimal
        );

        return (true, realReleaseAmount);
    }

    function releaseToTreasury(
        AssetType assetType
    )
        external
        afterStart
        alreadySetTreasuryVaultAddress
        onlyManager
        returns (bool success, uint256 amount)
    {
        if (
            releasedAsset[assetType] == 0 &&
            startTime + lockTimeInDays[assetType] * 1 days < block.timestamp
        ) {
            uint8 decimal = IERC20Decimals(asset).decimals();
            amount = canReleaseAsset[assetType];

            releasedAsset[assetType] = amount;

            IERC20(asset).safeTransfer(
                treasuryVaultAddress,
                amount * 10 ** decimal
            );

            return (true, amount);
        } else {
            return (false, 0);
        }
    }

    function passMulSign(
        address targetAddress,
        bytes[] calldata signList
    ) private view returns (bool) {
        require(
            signList.length == signerList.length,
            "sign list length not equal signer list count"
        );

        uint8 cnt = 0;
        bytes32 data = keccak256(abi.encode(targetAddress));
        for (uint256 i = 0; i < signList.length; i++) {
            if (_verify(data, signList[i], signerList[i])) {
                cnt++;
            }
        }

        if (cnt < threshold) {
            revert("mul sign check failed");
        }

        return true;
    }

    function getLinearCanReleaseMonth(
        AssetType assetType
    ) private view returns (uint) {
        uint canRealseTime = startTime + lockTimeInDays[assetType] * 1 days;
        uint canReleaseDays = (canRealseTime - block.timestamp) / 60 / 24;
        uint canReleaseMouth = 0;
        for (uint256 i = 0; i < dayCntOfMonth.length; i++) {
            if (canReleaseDays >= dayCntOfMonth[i]) {
                canReleaseMouth++;
                canReleaseDays -= dayCntOfMonth[i];
            } else {
                break;
            }
        }

        return canReleaseMouth;
    }

    modifier afterStart() {
        require(startTime > 0, "not start");
        _;
    }

    modifier afterLinearCanReleaseTime(AssetType assetType) {
        require(startTime > 0, "not start");
        uint canRealseTime = startTime + lockTimeInDays[assetType] * 1 days;
        require(canRealseTime < block.timestamp, "linear release not start");
        _;
    }

    modifier alreadySetTreasuryVaultAddress() {
        require(
            treasuryVaultAddress != address(0x0),
            "treasury vault address not set"
        );
        _;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "only manager can call");
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
            revert("mul sign check failed");
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

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
}
