// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../interfaces/IEmergencyStop.sol";

contract EmergencyStop is IEmergencyStop {
    bool withdrawDisable;

    function stopWithdraw() external {
        withdrawDisable = true;

        emit withdrawStoped();
    }

    function startWithdraw() external {
        withdrawDisable = false;

        emit withdrawStarted();
    }

    modifier withdrawIsDisable() {
        require(withdrawDisable == true, "withdraw not disable");
        _;
    }

    modifier withdrawIsEnable() {
        require(withdrawDisable == false, "withdraw not enable");
        _;
    }
}
