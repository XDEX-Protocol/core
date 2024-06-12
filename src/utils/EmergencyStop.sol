// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import "../interfaces/IEmergencyStop.sol";
import "../common/Errors.sol";

contract EmergencyStop is IEmergencyStop {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bool withdrawDisable;
    bool public alreadySet;
    address emergencyStopManager;
    address[] public emergencyStopSignerList;
    uint public emergencyStopThreshold;

    mapping(uint256 => bool) public _usedEmergencyStopStartNonce;

    function SetupEmergencyStop(
        address _manager,
        address[] memory _signerList,
        uint _threshold
    ) internal {
        require(!alreadySet, "can't reSetup");
        require(_manager != address(0x0), "Invalid manager address");
        require(
            _signerList.length >= _threshold,
            "Invalid number of required signatures"
        );
        alreadySet = true;

        emergencyStopManager = _manager;
        emergencyStopSignerList = _signerList;
        emergencyStopThreshold = _threshold;

        withdrawDisable = false;
    }

    modifier onlyEmergencyStopManager() {
        require(msg.sender == emergencyStopManager, "Only manager can call");
        _;
    }

    modifier onlyEmergencyStopMulSign(bytes32 data, bytes[] calldata signList) {
        if (signList.length != emergencyStopSignerList.length) {
            revert NeedMulSign();
        }

        uint8 cnt = 0;
        for (uint256 i = 0; i < signList.length; i++) {
            if (signList[i].length == 0) {
                continue;
            }

            if (
                _emergencyStopVerify(
                    data,
                    signList[i],
                    emergencyStopSignerList[i]
                )
            ) {
                cnt++;
            }
        }

        if (cnt < emergencyStopThreshold) {
            revert NeedMulSign();
        }
        _;
    }

    function _emergencyStopVerify(
        bytes32 data,
        bytes memory signature,
        address account
    ) internal pure returns (bool) {
        return data.toEthSignedMessageHash().recover(signature) == account;
    }

    function stopWithdraw() public onlyEmergencyStopManager {
        withdrawDisable = true;

        emit withdrawStoped();
    }

    function startWithdraw(
        uint256 nonce,
        bytes[] calldata signList
    ) public onlyEmergencyStopMulSign(keccak256(abi.encode(nonce)), signList) {
        _usedEmergencyStopStartNonce[nonce] = true;
        withdrawDisable = false;

        emit withdrawStarted();
    }

    function _isWithdrawalAllowed() internal view returns (bool) {
        return withdrawDisable == false;
    }
}
