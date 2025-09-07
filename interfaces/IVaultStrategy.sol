// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IVaultStrategy {
    function asset() external view returns (address);

    function deposit(address, uint256) external;

    function depositNative(address) external payable;

    function withdraw(address, uint256) external;

    function withdrawNative(address, uint256) external payable;

    function balanceOf() external view returns (uint256);
}
