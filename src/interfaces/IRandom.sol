// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/**
    provide random via client seed + contract seed
 */
interface IRandom {

    // @return random int num between [0, maxNum)
    function getRandomNum(
        bytes memory plantextContractSeed,
        bytes memory encryptContractSeed,
        bytes memory plantextClientSeed,
        int maxNum
    ) external view returns(int);

    // @return independentrandom int[] between [0, maxNum), which size of returnNumOfElements
    function getRandomNums(
        bytes memory plantextContractSeed,
        bytes memory encryptContractSeed,
        bytes memory plantextClientSeed,
        int maxNum,
        int returnNumOfElements
    ) external view returns(int[] memory);

    // @return a random shuffled array of [0, numOfElements)
    function shuffle(
        bytes memory plantextContractSeed,
        bytes memory encryptContractSeed,
        bytes memory plantextClientSeed,
        int numOfElements
    ) external view returns(int[] memory);

}
