// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IPool.sol";
import "./interfaces/ILPManager.sol";
import "./libraries/X18Helper.sol";
import "./common/Errors.sol";

contract Pool is IPool, ERC20 {
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;
    using Math for uint256;

    uint8 decimal;
    address public manager;
    bool enableTransfer;

    constructor(
        string memory _shareName,
        string memory _shareSymbol,
        uint8 _decimal
    ) ERC20(_shareName, _shareSymbol) {
        decimal = _decimal;

        manager = msg.sender;
        enableTransfer = false;
    }

    function buyShare(address user, uint256 share) external onlyPoolManager {
        _mint(user, share);
    }

    function burnRedeemShare(uint256 burnShare) external onlyPoolManager {
        _burn(address(this), burnShare);
    }

    function rejectRedeemShare(
        address rejectAddress,
        uint256 share
    ) external onlyPoolManager {
        IERC20(this).safeTransferFrom(address(this), rejectAddress, share);
    }

    // ==================== erc20 part ====================
    function decimals() public view virtual override returns (uint8) {
        return decimal;
    }

    function transfer(
        address to,
        uint256 value
    ) public virtual override(ERC20, IERC20) returns (bool) {
        if (!enableTransfer) {
            require(
                to == address(this) || to == address(0x0),
                "can't transfer"
            );
        }
        address owner = _msgSender();
        _transfer(owner, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public virtual override(ERC20, IERC20) returns (bool) {
        if (!enableTransfer) {
            require(
                to == address(this) || to == address(0x0),
                "can't transfer"
            );
        }
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    // ==================== manager area ====================

    function enableTransferOn() external onlyPoolManager {
        enableTransfer = true;
    }

    function enableTransferOff() external onlyPoolManager {
        enableTransfer = false;
    }

    modifier onlyPoolManager() {
        if (msg.sender != manager) {
            revert OnlyManagerCanCall();
        }
        _;
    }
}
