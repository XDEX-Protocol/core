// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IVault.sol";
import "./common/Constants.sol";
import "./common/Errors.sol";

contract Vault is IVault {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    string public name;
    address public manager;
    address[] public mulSigners;
    uint public threshold;

    constructor(
        string memory _name,
        address _manager,
        address[] memory _mulSigners,
        uint _threshold
    ) {
        require(_manager != address(0x0), "invalid manager address");
        require(_mulSigners.length > 0, "invalid signer list");
        require(_threshold <= _mulSigners.length, "invalid threshold");

        name = _name;
        manager = _manager;
        mulSigners = new address[](_mulSigners.length);

        for (uint256 index = 0; index < _mulSigners.length; index++) {
            mulSigners[index] = _mulSigners[index];
        }

        threshold = _threshold;
    }

    receive() external payable {}

    // ==================== withdraw ====================

    function withdraw(
        address to,
        address token,
        uint256 amount
    ) external onlyManager {
        IERC20(token).safeTransfer(to, amount);

        emit withdrawProcessed(to, token, amount);
    }

    // ==================== manager area ====================

    modifier onlyManager() {
        if (msg.sender != manager) {
            revert OnlyManagerCanCall();
        }
        _;
    }
}
