// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "../interfaces/IERC20Decimals.sol";

library X18Helper {
    /// @dev convert number to x18
    /// ie. asset decimal is 6, assetAmount is 1_000_000 (1 asset token), this will return 1_000_000_000_000
    function toX18(
        uint256 assetAmount,
        address asset
    ) internal view returns (uint256 assetAmountX18) {
        uint8 decimal = IERC20Decimals(asset).decimals();
        return assetAmount * 10 ** (18 - decimal);
    }

    function fromX18ToNormalDecimal(
        uint256 assetAmountX18,
        address asset
    ) internal view returns (uint256 assetAmount) {
        uint8 decimal = IERC20Decimals(asset).decimals();
        return assetAmountX18 / (10 ** (18 - decimal));
    }

    function fromX18ToNormalDecimal(
        uint256 assetAmountX18,
        uint8 decimal
    ) internal pure returns (uint256 assetAmount) {
        return assetAmountX18 / (10 ** (18 - decimal));
    }

    function convertDecimalToTargetToken(
        uint256 amountWithOriginDecimal,
        address originAsset,
        address targetAsset
    ) internal view returns (uint256 amount) {
        uint8 originDecimal = IERC20Decimals(originAsset).decimals();
        uint8 targetDecimal = IERC20Decimals(targetAsset).decimals();

        amount =
            (amountWithOriginDecimal * 10 ** targetDecimal) /
            10 ** originDecimal;

        return amount;
    }

    function addAssetDecimal(
        uint256 amount,
        address asset
    ) internal view returns (uint256 amountWithDecimal) {
        uint8 decimal = IERC20Decimals(asset).decimals();
        amountWithDecimal = amount * 10 ** decimal;
        return amountWithDecimal;
    }

    function removeAssetDecimal(
        uint256 amount,
        address asset
    ) internal view returns (uint256 amountWithDecimal) {
        uint8 decimal = IERC20Decimals(asset).decimals();
        amountWithDecimal = amount / 10 ** decimal;
        return amountWithDecimal;
    }

    function removeAssetDecimal(
        uint256 amount,
        uint8 decimal
    ) internal pure returns (uint256 amountWithDecimal) {
        amountWithDecimal = amount / 10 ** decimal;
        return amountWithDecimal;
    }
}
