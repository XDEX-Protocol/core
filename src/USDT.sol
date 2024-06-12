// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract USDT is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    uint8 _decimal;

    mapping(address => bool) public manager;
    mapping(address => uint256) public lastRequest;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        string memory name,
        string memory symbol,
        uint8 decimal
    ) public initializer {
        __ERC20_init(name, symbol);
        __Ownable_init(initialOwner);
        __UUPSUpgradeable_init();

        _decimal = decimal;
        manager[initialOwner] = true;
        manager[msg.sender] = true;
    }

    function requestCoin() public {
        require(
            lastRequest[msg.sender] + 1 days <= block.timestamp,
            "Please try again tomorrow"
        );

        lastRequest[msg.sender] = block.timestamp;

        _mint(msg.sender, 10000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public onlyManager {
        _mint(to, amount);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}

    function decimals() public view virtual override returns (uint8) {
        return _decimal;
    }

    function addManager(address newManager) public onlyManager {
        manager[newManager] = true;
    }

    function deleteManager(address manager_) public onlyManager {
        manager[manager_] = false;
    }

    modifier onlyManager() {
        require(manager[msg.sender], "only manager can call");
        _;
    }
}
